import Foundation

public enum TaskSchedule: Codable, Sendable, Equatable {
    case manual, once(Date), hourly(minute: Int), daily(hour: Int, minute: Int), weekdays(hour: Int, minute: Int), weekly(day: Int, hour: Int, minute: Int), interval(minutes: Int)
    public func validate() throws {
        switch self {
        case .manual: break
        case .once(let date): guard date.timeIntervalSince1970.isFinite else { throw ACPError.workspace("Invalid scheduled time.") }
        case .interval(let minutes): guard (1...10080).contains(minutes) else { throw ACPError.workspace("Choose an interval from one minute to seven days.") }
        case .hourly(let minute): guard (0...59).contains(minute) else { throw ACPError.workspace("Invalid minute.") }
        case .daily(let hour, let minute), .weekdays(let hour, let minute): guard (0...23).contains(hour), (0...59).contains(minute) else { throw ACPError.workspace("Invalid scheduled time.") }
        case .weekly(let day, let hour, let minute): guard (1...7).contains(day), (0...23).contains(hour), (0...59).contains(minute) else { throw ACPError.workspace("Invalid scheduled day/time.") }
        }
    }
    public func latest(onOrBefore now: Date, timezone: String, anchor: Date) throws -> Date? {
        try validate()
        guard let zone = TimeZone(identifier: timezone), now.timeIntervalSince1970.isFinite else { throw ACPError.workspace("Choose a valid scheduling timezone.") }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        var matching = DateComponents(); matching.second = 0
        switch self {
        case .manual: return nil
        case .once(let time): return time <= now ? time : nil
        case .interval(let minutes):
            let seconds = Double(minutes * 60), steps = floor(now.timeIntervalSince(anchor) / seconds)
            return steps >= 1 ? anchor.addingTimeInterval(steps * seconds) : nil
        case .hourly(let minute): matching.minute = minute
        case .daily(let hour, let minute), .weekdays(let hour, let minute): matching.hour = hour; matching.minute = minute
        case .weekly(let day, let hour, let minute): matching.weekday = day; matching.hour = hour; matching.minute = minute
        }
        if matching.hour != nil {
            // Resolve each wall-clock day forward. Backward matching chooses
            // the later DST repetition even with repeatedTimePolicy=.first.
            let today = calendar.startOfDay(for: now)
            for offset in 0..<8 {
                guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
                let weekday = calendar.component(.weekday, from: day)
                if case .weekdays = self, [1, 7].contains(weekday) { continue }
                if let requested = matching.weekday, requested != weekday { continue }
                var clock = matching; clock.weekday = nil
                guard let found = calendar.nextDate(after: day.addingTimeInterval(-0.001), matching: clock, matchingPolicy: .nextTime, repeatedTimePolicy: .first),
                      calendar.isDate(found, inSameDayAs: day), found <= now else { continue }
                return found
            }
            return nil
        }
        // Hourly schedules use the same first-occurrence policy. Resolving
        // forward from each day's start avoids the repeated-hour backward trap.
        let today = calendar.startOfDay(for: now)
        for offset in 0..<2 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            for hour in stride(from: offset == 0 ? calendar.component(.hour, from: now) : 23, through: 0, by: -1) {
                var clock = matching; clock.hour = hour
                if let found = calendar.nextDate(after: day.addingTimeInterval(-0.001), matching: clock, matchingPolicy: .nextTime, repeatedTimePolicy: .first), calendar.isDate(found, inSameDayAs: day), found <= now { return found }
            }
        }
        return nil
    }
    public var title: String {
        switch self {
        case .manual: "Manual"
        case .once: "Once"
        case .hourly: "Hourly"
        case .daily: "Daily"
        case .weekdays: "Weekdays"
        case .weekly: "Weekly"
        case .interval(let minutes): "Every \(minutes) minutes"
        }
    }
}

public struct ScheduledTask: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var revision: UUID
    public var name: String
    public var instructions: String
    public var projectPath: String
    public var configuration: SessionConfiguration
    public var worktree: Bool
    public var branch: String?
    public var schedule: TaskSchedule
    public var timezone: String
    public var active: Bool
    public var archived: Bool
    public let createdAt: Date
    public var lastConsidered: Date
    public init(id: UUID = UUID(), name: String, instructions: String, projectPath: String, configuration: SessionConfiguration, worktree: Bool = false, branch: String? = nil, schedule: TaskSchedule = .manual, timezone: String = TimeZone.current.identifier, createdAt: Date = Date()) throws {
        self.id = id; revision = UUID(); self.name = name; self.instructions = instructions; self.projectPath = projectPath; self.configuration = configuration
        self.worktree = worktree; self.branch = branch; self.schedule = schedule; self.timezone = timezone; active = true; archived = false; self.createdAt = createdAt; lastConsidered = createdAt
        try validate()
    }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 128,
              !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, instructions.utf8.count <= 64 * 1024,
              configuration.executable.hasPrefix("/"), !configuration.executable.contains("\0"), configuration.arguments.count <= 256,
              configuration.arguments.allSatisfy({ !$0.contains("\0") }), (try JSONEncoder().encode(configuration)).count <= 128 * 1024,
              TimeZone(identifier: timezone) != nil, createdAt.timeIntervalSince1970.isFinite, lastConsidered.timeIntervalSince1970.isFinite else { throw ACPError.workspace("Enter a name, instructions, local project, valid timezone and ACP launch choices.") }
        _ = try WorkspaceLocation(path: projectPath); try schedule.validate()
    }
}

public enum ScheduledRunState: String, Codable, Sendable, Equatable {
    case launching, running, needsApproval, cancelling, completed, failed, cancelled, interrupted, skipped
    public var isActive: Bool { [.launching, .running, .needsApproval, .cancelling].contains(self) }
    public var title: String { switch self { case .needsApproval: "Needs attention"; default: rawValue.capitalized } }
}
public struct ScheduledRun: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let taskID: UUID
    public let taskRevision: UUID
    public let sessionID: UUID
    public let scheduledAt: Date
    public let startedAt: Date
    public let catchUp: Bool
    public var state: ScheduledRunState
    public var detail: String?
    public var endedAt: Date?
    public init(task: ScheduledTask, scheduledAt: Date, startedAt: Date, catchUp: Bool = false, state: ScheduledRunState = .launching, detail: String? = nil) {
        id = UUID(); taskID = task.id; taskRevision = task.revision; sessionID = id; self.scheduledAt = scheduledAt; self.startedAt = startedAt; self.catchUp = catchUp; self.state = state; self.detail = detail
        if !state.isActive { endedAt = startedAt }
    }
}
public struct ScheduledOrigin: Codable, Sendable, Equatable {
    public let taskID: UUID
    public let runID: UUID
    public let taskRevision: UUID
    public let taskName: String
    public init(task: ScheduledTask, run: ScheduledRun) { taskID = task.id; runID = run.id; taskRevision = run.taskRevision; taskName = task.name }
}
public struct ScheduledLaunch: Sendable { public let task: ScheduledTask; public let run: ScheduledRun }
public struct ScheduledBook: Codable, Sendable, Equatable {
    public var version = 1
    public var revision = 0
    public var tasks: [ScheduledTask] = []
    public var runs: [ScheduledRun] = []
    public init() {}
    public func validate() throws {
        guard version == 1, revision >= 0, tasks.count <= 128, runs.count <= 2048,
              Set(tasks.map(\.id)).count == tasks.count, Set(runs.map(\.id)).count == runs.count,
              Set(tasks.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }).count == tasks.count,
              runs.allSatisfy({ run in tasks.contains { $0.id == run.taskID } && run.sessionID == run.id && (run.detail?.utf8.count ?? 0) <= 4096 }) else { throw ACPError.workspace("Invalid or oversized local routine history.") }
        for task in tasks { try task.validate() }
    }
}
