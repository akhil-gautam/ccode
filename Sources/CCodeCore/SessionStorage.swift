import Foundation

public actor SessionStorage {
    public let directory: URL
    private let claudeDirectory: URL?
    public init(directory: URL, claudeDirectory: URL? = nil) {
        self.directory = directory
        if let claudeDirectory { self.claudeDirectory = claudeDirectory }
        else if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] { self.claudeDirectory = override.hasPrefix("/") ? URL(fileURLWithPath: override) : nil }
        else { self.claudeDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude") }
    }
    public func loadClaudeTranscript(sessionID: String, cwd: String) async throws -> SessionTranscript? {
        guard let claudeDirectory else { return nil }
        let read = Task.detached { try ClaudeTranscriptReader.load(sessionID: sessionID, cwd: cwd, configurationDirectory: claudeDirectory) }
        return try await withTaskCancellationHandler { try await read.value } onCancel: { read.cancel() }
    }
    public func list() throws -> [SessionInfo] {
        let url = directory.appendingPathComponent("index.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([SessionInfo].self, from: Data(contentsOf: url))
    }
    public func load(_ id: UUID) throws -> SessionTranscript {
        let url = directory.appendingPathComponent("\(id).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return SessionTranscript() }
        let value = try JSONDecoder().decode(SessionTranscript.self, from: Data(contentsOf: url))
        guard value.version == 1 else { throw ACPError.workspace("Unsupported transcript version \(value.version).") }
        return value
    }
    public func loadPeerMessages(_ recipientID: UUID) throws -> [PeerMessage] {
        let file = directory.appendingPathComponent("peer-inbox-\(recipientID).json")
        guard FileManager.default.fileExists(atPath:file.path) else { return [] }
        let messages = try JSONDecoder().decode([PeerMessage].self,from:Data(contentsOf:file))
        guard messages.count <= 128, Set(messages.map(\.id)).count == messages.count,
              messages.allSatisfy({ $0.recipientID == recipientID && $0.senderID != recipientID && $0.body.utf8.count <= 16*1024 }) else { throw ACPError.workspace("Invalid agent message inbox.") }
        return messages
    }
    public func appendPeerMessage(_ message: PeerMessage) throws {
        var messages = try loadPeerMessages(message.recipientID)
        if let existing=messages.first(where:{ $0.id == message.id }) {
            guard existing == message else { throw ACPError.workspace("Agent message receipt identity collision.") };return
        }
        guard messages.count < 128 else { throw ACPError.workspace("Recipient inbox is full. Remove old messages before sending more.") }
        messages.append(message);try write(messages,to:"peer-inbox-\(message.recipientID).json")
    }
    public func removePeerMessage(_ id:UUID,recipientID:UUID) throws {
        var messages=try loadPeerMessages(recipientID);messages.removeAll { $0.id == id }
        try write(messages,to:"peer-inbox-\(recipientID).json")
    }
    public func loadAgentCatalog() throws -> AgentCatalog? {
        let url = directory.appendingPathComponent("agent-options.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(AgentCatalog.self, from: Data(contentsOf: url))
    }
    public func saveAgentCatalog(_ catalog: AgentCatalog) throws { try write(catalog, to: "agent-options.json") }
    public func loadNewSessionDraft() throws -> NewSessionDraft? {
        let url = directory.appendingPathComponent("new-session-draft.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(NewSessionDraft.self, from: Data(contentsOf: url))
    }
    public func saveNewSessionDraft(_ draft: NewSessionDraft) throws { try write(draft, to: "new-session-draft.json") }
    public func saveIndex(_ summaries: [SessionInfo]) throws { try write(summaries, to: "index.json") }
    public func loadScheduledBook() throws -> ScheduledBook {
        let file = directory.appendingPathComponent("routines.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return ScheduledBook() }
        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 12 * 1024 * 1024 else { throw ACPError.workspace("Routine history exceeds its storage limit.") }
        let book = try JSONDecoder().decode(ScheduledBook.self, from: Data(contentsOf: file)); try book.validate(); return book
    }
    private func saveScheduledBook(_ value: ScheduledBook) throws -> ScheduledBook {
        var book = value; book.revision += 1
        while book.runs.count > 2048, let index = book.runs.firstIndex(where: { !$0.state.isActive }) { book.runs.remove(at: index) }
        try book.validate(); try write(book, to: "routines.json", maximumBytes: 12 * 1024 * 1024); return book
    }
    public func saveScheduledTask(_ task: ScheduledTask, expecting revision: UUID?, at now: Date = Date()) throws -> ScheduledBook {
        try task.validate(); var book = try loadScheduledBook()
        var updated = task
        if let index = book.tasks.firstIndex(where: { $0.id == task.id }) {
            guard revision == book.tasks[index].revision else { throw ACPError.workspace("This routine changed. Reopen the editor before saving.") }
            updated.lastConsidered = task.schedule == book.tasks[index].schedule && task.timezone == book.tasks[index].timezone ? book.tasks[index].lastConsidered : now
            updated.revision = UUID(); book.tasks[index] = updated
        } else {
            guard revision == nil else { throw ACPError.workspace("Routine no longer exists.") }
            book.tasks.append(task)
        }
        return try saveScheduledBook(book)
    }
    public func setScheduledTaskActive(_ id: UUID, active: Bool, at now: Date) throws -> ScheduledBook {
        var book = try loadScheduledBook()
        guard let i = book.tasks.firstIndex(where: { $0.id == id && !$0.archived }) else { throw ACPError.workspace("Routine is unavailable.") }
        book.tasks[i].active = active; book.tasks[i].revision = UUID(); book.tasks[i].lastConsidered = now
        return try saveScheduledBook(book)
    }
    public func archiveScheduledTask(_ id: UUID) throws -> ScheduledBook {
        var book = try loadScheduledBook()
        guard let i = book.tasks.firstIndex(where: { $0.id == id }) else { throw ACPError.workspace("Routine is unavailable.") }
        book.tasks[i].active = false; book.tasks[i].archived = true; book.tasks[i].revision = UUID()
        return try saveScheduledBook(book)
    }
    public func claimManualScheduledRun(_ id: UUID, expecting revision: UUID?, at now: Date, busyTasks: Set<UUID>, limit: Int = 3) throws -> ScheduledLaunch {
        var book = try loadScheduledBook()
        guard let task = book.tasks.first(where: { $0.id == id && !$0.archived }), revision == nil || task.revision == revision else { throw ACPError.workspace("Routine changed or is unavailable. Reopen it before running.") }
        let busy = Set(book.runs.filter { $0.state.isActive }.map(\.taskID)).union(busyTasks)
        guard !busy.contains(id), busy.count < limit else { throw ACPError.workspace("Wait for the previous run or other local routines to finish.") }
        let run = ScheduledRun(task: task, scheduledAt: now, startedAt: now); book.runs.append(run)
        _ = try saveScheduledBook(book)
        return ScheduledLaunch(task: task, run: run)
    }
    public func claimDueScheduledRuns(at now: Date, busyTasks: Set<UUID>, limit: Int = 3) throws -> [ScheduledLaunch] {
        var book = try loadScheduledBook(), launches: [ScheduledLaunch] = []
        var busy = Set(book.runs.filter { $0.state.isActive }.map(\.taskID)).union(busyTasks)
        var changed = false
        for i in book.tasks.indices {
            let task = book.tasks[i]
            guard task.active, !task.archived, let due = try task.schedule.latest(onOrBefore: now, timezone: task.timezone, anchor: task.createdAt), due > task.lastConsidered else { continue }
            changed = true; book.tasks[i].lastConsidered = due
            if case .once = task.schedule { book.tasks[i].active = false }
            let detail: String? = due < now.addingTimeInterval(-7 * 86400) ? "Missed run is older than seven days." : busy.contains(task.id) ? "The previous run is still in progress." : busy.count >= limit ? "Other scheduled tasks are already running." : nil
            let run = ScheduledRun(task: task, scheduledAt: due, startedAt: now, catchUp: now.timeIntervalSince(due) > 60, state: detail == nil ? .launching : .skipped, detail: detail)
            book.runs.append(run)
            if detail == nil { busy.insert(task.id); launches.append(ScheduledLaunch(task: task, run: run)) }
        }
        if changed { _ = try saveScheduledBook(book) }
        return launches
    }
    public func updateScheduledRun(_ id: UUID, state: ScheduledRunState, detail: String?, at now: Date) throws -> ScheduledBook {
        var book = try loadScheduledBook()
        guard let i = book.runs.firstIndex(where: { $0.id == id }) else { throw ACPError.workspace("Run no longer exists.") }
        // Terminal outcomes are immutable; an older worker cannot revive a cancelled run.
        guard book.runs[i].state.isActive else { return book }
        if book.runs[i].state == .cancelling, state.isActive, state != .cancelling { return book }
        if book.runs[i].state == state, book.runs[i].detail == detail { return book }
        book.runs[i].state = state; book.runs[i].detail = detail.map { String($0.prefix(1024)) }
        if !state.isActive { book.runs[i].endedAt = now }
        return try saveScheduledBook(book)
    }
    public func recoverScheduledRuns(at now: Date) throws -> ScheduledBook {
        var book = try loadScheduledBook(); var changed = false
        for i in book.runs.indices where book.runs[i].state.isActive {
            book.runs[i].state = .interrupted; book.runs[i].endedAt = now
            book.runs[i].detail = "App stopped before completion was confirmed. Inspect its session; this run will not be replayed."
            changed = true
        }
        return changed ? try saveScheduledBook(book) : book
    }
    public func loadSidebarPreferences() throws -> SidebarPreferences {
        let url = directory.appendingPathComponent("sidebar.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return SidebarPreferences() }
        return try JSONDecoder().decode(SidebarPreferences.self, from: Data(contentsOf: url))
    }
    public func saveSidebarPreferences(_ preferences: SidebarPreferences) throws { try write(preferences, to: "sidebar.json") }
    public func loadPaneLayout() throws -> PaneLayout? {
        let url = directory.appendingPathComponent("panes.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(PaneLayout.self, from: Data(contentsOf: url))
    }
    public func savePaneLayout(_ layout: PaneLayout) throws { try write(layout, to: "panes.json") }
    public func save(_ transcript: SessionTranscript, id: UUID) throws { try write(transcript, to: "\(id).json") }
    public func prepareCheckpointRecoveryDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = directory.resolvingSymlinksInPath().appendingPathComponent("checkpoint-recovery", isDirectory: true)
        if FileManager.default.fileExists(atPath: root.path) {
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw ACPError.workspace("Checkpoint recovery folder is not a private directory.") }
        } else { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        return root
    }
    public func discardUnpublished(_ id: UUID) throws {
        guard try list().contains(where: { $0.id == id }) == false else { throw ACPError.workspace("Saved history cannot be discarded as an unpublished session.") }
        let file = directory.appendingPathComponent("\(id).json")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
    private func write<T: Encodable>(_ value: T, to name: String, maximumBytes: Int? = nil) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bytes = try JSONEncoder().encode(value)
        if let maximumBytes, bytes.count > maximumBytes { throw ACPError.workspace("Routine history exceeds its storage limit. Shorten routine instructions or saved agent configuration.") }
        try bytes.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}
