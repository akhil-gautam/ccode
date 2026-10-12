import Foundation

public struct SidebarPreferences: Codable, Sendable, Equatable {
    public var collapsedProjects: Set<String> = []
    public var pinnedProjects: Set<String> = []
    public var projectOrder: [String] = []
    public init() {}
}

// Built when metadata/search changes; rendering and scrolling only read this value.
public struct SidebarSnapshot: Sendable {
    public enum Row: Identifiable, Sendable {
        case pinned, project(String), session(SessionInfo)
        public var id: String {
            switch self {
            case .pinned: "pinned"
            case .project(let path): "project:" + path
            case .session(let info): "session:" + info.id.uuidString
            }
        }
    }
    public let visible: [SessionInfo]
    public let projects: [String]
    public let sessionOrder: [SessionInfo]
    public let rows: [Row]
    public init(sessions: [SessionInfo] = [], search: String = "", archived: Bool = false, preferences: SidebarPreferences = SidebarPreferences(), projectScope: String? = nil, activities: [UUID: SessionActivity] = [:], status: SessionActivity? = nil) {
        visible = sessions.filter { $0.archived == archived && (status == nil || (activities[$0.id] ?? $0.persistedActivity) == status) && (projectScope == nil || $0.projectGroupingPath == projectScope) && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.projectName.localizedCaseInsensitiveContains(search)) }
            .sorted { a, b in
                if a.pinned != b.pinned { return a.pinned }
                if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
                return a.id.uuidString < b.id.uuidString
            }
        let pinned = visible.filter(\.pinned)
        let groups = Dictionary(grouping: visible.filter { !$0.pinned }, by: \.projectGroupingPath)
        var ranks: [String: Int] = [:]
        for (rank, path) in preferences.projectOrder.enumerated() where ranks[path] == nil { ranks[path] = rank }
        projects = groups.keys.sorted {
            let pinnedA = preferences.pinnedProjects.contains($0), pinnedB = preferences.pinnedProjects.contains($1)
            if pinnedA != pinnedB { return pinnedA }
            let rankA = ranks[$0] ?? Int.max, rankB = ranks[$1] ?? Int.max
            if rankA != rankB { return rankA < rankB }
            let order = URL(fileURLWithPath: $0).lastPathComponent.localizedStandardCompare(URL(fileURLWithPath: $1).lastPathComponent)
            return order == .orderedSame ? $0 < $1 : order == .orderedAscending
        }
        var entries: [Row] = pinned.isEmpty ? [] : [.pinned] + pinned.map(Row.session)
        var order = pinned
        for project in projects {
            let sessions = groups[project] ?? []
            entries.append(.project(project))
            if !preferences.collapsedProjects.contains(project) || !search.isEmpty || projectScope != nil { entries.append(contentsOf: sessions.map(Row.session)) }
            order += sessions
        }
        rows = entries; sessionOrder = order
    }
}
