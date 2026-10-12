import Foundation

@main struct SidebarBenchmark {
    static func main() {
        let count = 10_000
        let sessions = (0..<count).map { i in
            var info = SessionInfo(projectPath: "/projects/project-\(i % 200)", title: "Session \(i)")
            info.updatedAt = Date(timeIntervalSince1970: Double(i)); return info
        }
        func milliseconds(_ operation: () -> Int) -> Double {
            let start = ContinuousClock.now
            precondition(operation() == count)
            let duration = start.duration(to: .now).components
            return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
        }
        // Previous production sidebar ordering: repeated sorts and one filter per project.
        func previous() -> Int {
            let visible = sessions.sorted { $0.updatedAt > $1.updatedAt }
            let projects = Array(Set(visible.map(\.projectPath))).sorted {
                let comparison = URL(fileURLWithPath: $0).lastPathComponent.localizedStandardCompare(URL(fileURLWithPath: $1).lastPathComponent)
                return comparison == .orderedSame ? $0 < $1 : comparison == .orderedAscending
            }
            return projects.flatMap { path in visible.filter { $0.projectPath == path && !$0.pinned } }.count
        }
        let start = ContinuousClock.now
        let snapshot = SidebarSnapshot(sessions: sessions)
        let build = start.duration(to: .now).components
        precondition(snapshot.rows.count == count + 200)
        precondition(Set(snapshot.rows.map(\.id)).count == snapshot.rows.count)
        var previousSamples: [Double] = [], cachedSamples: [Double] = []
        for _ in 0..<20 { previousSamples.append(milliseconds(previous)); cachedSamples.append(milliseconds { snapshot.sessionOrder.count }) }
        previousSamples.sort(); cachedSamples.sort()
        print("rows=\(count), projects=200, samples=20")
        print(String(format: "snapshot_build_ms=%.3f", Double(build.seconds) * 1_000 + Double(build.attoseconds) / 1e15))
        print(String(format: "previous_index_p95_ms=%.3f, cached_access_p95_ms=%.6f", previousSamples[18], cachedSamples[18]))
        print("Headless metadata measurement; native scroll frame pacing is separate.")
    }
}
