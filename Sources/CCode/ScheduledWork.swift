import Foundation
import CCodeCore

extension AppStore {
    var localRoutineSource: ChatSession? {
        guard let chat = selected, chat.workspace.environment.isLocal else { return nil }
        return chat
    }
    func publishScheduledBook(_ book: ScheduledBook) {
        if book.revision >= scheduledBook.revision, book != scheduledBook { scheduledBook = book }
    }
    func loadLocalSchedules(recover: Bool = false, at now: Date = Date()) async {
        do { publishScheduledBook(try await recover ? storage.recoverScheduledRuns(at: now) : storage.loadScheduledBook()) }
        catch { scheduledError = error.localizedDescription }
    }
    func saveScheduledTask(_ task: ScheduledTask, expecting revision: UUID?) async throws {
        guard canRunScheduledWork else { throw ACPError.workspace("App is shutting down.") }
        _ = try Workspace(root: task.projectPath)
        guard FileManager.default.isExecutableFile(atPath: task.configuration.executable) else { throw ACPError.workspace("Choose an installed ACP executable before saving this routine.") }
        publishScheduledBook(try await storage.saveScheduledTask(task, expecting: revision)); scheduledError = nil
    }
    func setScheduledTaskActive(_ id: UUID, active: Bool, at now: Date = Date()) async throws {
        guard canRunScheduledWork else { throw ACPError.workspace("App is shutting down.") }
        publishScheduledBook(try await storage.setScheduledTaskActive(id, active: active, at: now))
    }
    func archiveScheduledTask(_ id: UUID) async throws {
        guard canRunScheduledWork else { throw ACPError.workspace("App is shutting down.") }
        publishScheduledBook(try await storage.archiveScheduledTask(id))
    }
    private var busyScheduledTasks: Set<UUID> {
        Set(scheduledBook.runs.compactMap { run in
            guard scheduledRunTasks[run.id] != nil || chat(run.sessionID).map({ $0.busy || $0.hasLiveAgentWork || $0.hasPendingDecisions }) == true else { return nil }
            return run.taskID
        })
    }
    @discardableResult func runScheduledTask(_ id: UUID, expecting revision: UUID? = nil, at now: Date = Date()) async throws -> UUID {
        guard canRunScheduledWork else { throw ACPError.workspace("App is shutting down.") }
        let launch = try await storage.claimManualScheduledRun(id, expecting: revision, at: now, busyTasks: busyScheduledTasks)
        await loadLocalSchedules(); launchScheduledWork(launch)
        return launch.run.id
    }
    func sweepScheduledTasks(at now: Date) async {
        guard canRunScheduledWork else { return }
        do {
            let launches = try await storage.claimDueScheduledRuns(at: now, busyTasks: busyScheduledTasks)
            await loadLocalSchedules()
            for launch in launches { launchScheduledWork(launch) }
        } catch { scheduledError = error.localizedDescription }
    }
    func startLocalScheduling() {
        guard scheduleLoop == nil, canRunScheduledWork else { return }
        scheduleLoop = Task { [weak self] in
            await self?.loadLocalSchedules(recover: true)
            while !Task.isCancelled {
                await self?.sweepScheduledTasks(at: Date())
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }
    func stopLocalScheduling() async {
        scheduleLoop?.cancel(); await scheduleLoop?.value; scheduleLoop = nil
        let workers = Array(scheduledRunTasks.values)
        for worker in workers { worker.cancel() }
        for worker in workers { await worker.value }
    }
    private func updateScheduledState(_ id: UUID, _ state: ScheduledRunState, detail: String? = nil) async {
        do { publishScheduledBook(try await storage.updateScheduledRun(id, state: state, detail: detail, at: Date())) }
        catch { scheduledError = "Could not save run status: " + error.localizedDescription }
    }
    private func launchScheduledWork(_ launch: ScheduledLaunch) {
        guard scheduledRunTasks[launch.run.id] == nil else { return }
        scheduledRunTasks[launch.run.id] = Task { [weak self] in
            guard let self else { return }
            let id = launch.run.id
            defer { scheduledRunTasks.removeValue(forKey: id); scheduledCancellationRequests.remove(id) }
            var target: ChatSession?
            do {
                try Task.checkCancellation()
                guard canRunScheduledWork, !scheduledCancellationRequests.contains(id), scheduledBook.runs.first(where: { $0.id == id })?.state == .launching else { return }
                guard let session = await create(path: launch.task.projectPath, worktree: launch.task.worktree, initialPrompt: launch.task.instructions, configuration: launch.task.configuration, branch: launch.task.branch, sessionID: launch.run.sessionID, select: false, scheduledOrigin: ScheduledOrigin(task: launch.task, run: launch.run)), let chat = chat(session) else { throw ACPError.workspace("Could not create the scheduled session. Inspect its saved state before retrying.") }
                target = chat
                defer { chat.launching = false }
                try Task.checkCancellation()
                guard canRunScheduledWork, !scheduledCancellationRequests.contains(id) else { throw CancellationError() }
                // Configuration belongs to this snapshot's exact executable,
                // never the current global/Home choices.
                chat.launching = false
                startPrompt(chat, text: launch.task.instructions, attachments: [])
                guard let prompt = chat.promptTask else { throw ACPError.workspace("Scheduled prompt could not start; its draft is preserved.") }
                let observer = Task { [weak self, weak chat] in
                    while !Task.isCancelled, let self, let chat {
                        await self.updateScheduledState(id, chat.hasPendingDecisions ? .needsApproval : .running)
                        do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                    }
                }
                await withTaskCancellationHandler { await prompt.value } onCancel: { Task { @MainActor [weak self, weak chat] in if let chat { self?.stop(chat) } } }
                observer.cancel(); await observer.value
                try Task.checkCancellation()
                while chat.hasLiveAgentWork {
                    await updateScheduledState(id, chat.hasPendingDecisions ? .needsApproval : .running)
                    try await Task.sleep(for: .milliseconds(200))
                }
                guard canRunScheduledWork, !scheduledCancellationRequests.contains(id) else { throw CancellationError() }
                if let error = chat.lastError { await updateScheduledState(id, .failed, detail: error) }
                else if let delivery = chat.transcript.items.first(where: { $0.kind == "user" && $0.text == launch.task.instructions }) {
                    if delivery.deliveryState == .cancelled || delivery.deliveryStopReason == "cancelled" { await updateScheduledState(id, .cancelled, detail: "Response stopped. Its session is preserved.") }
                    else if delivery.deliveryState != .acknowledged || delivery.deliveryStopReason != "end_turn" { await updateScheduledState(id, .interrupted, detail: "Completion was not confirmed. Inspect the owning session; this run will not replay.") }
                    else {
                        let childFailed = (chat.transcript.subagents ?? []).contains { chat.childOwners.contains($0.id) && $0.state == "failed" }
                            || (chat.transcript.asyncTasks ?? []).contains { chat.asyncTaskOwners.contains($0.id) && $0.state == .failed }
                        await updateScheduledState(id, childFailed ? .failed : .completed, detail: childFailed ? "Delegated work failed. Inspect the owning session." : nil)
                    }
                } else { await updateScheduledState(id, .failed, detail: "Prompt was not delivered; inspect the preserved draft.") }
            } catch {
                if error is CancellationError {
                    if let target { stop(target); await target.promptTask?.value }
                    let uncertain = !canRunScheduledWork || target?.hasLiveAgentWork == true
                    await updateScheduledState(id, uncertain ? .interrupted : .cancelled, detail: uncertain ? "Completion was not confirmed. Inspect the owning session; this run will not replay." : "Run stopped. Its session and results are preserved.")
                } else { await updateScheduledState(id, .failed, detail: error.localizedDescription) }
            }
        }
    }
    func cancelScheduledRun(_ id: UUID) async throws {
        guard let run = scheduledBook.runs.first(where: { $0.id == id }), run.state.isActive else { return }
        scheduledCancellationRequests.insert(id)
        publishScheduledBook(try await storage.updateScheduledRun(id, state: .cancelling, detail: nil, at: Date()))
        let worker = scheduledRunTasks[id]; worker?.cancel()
        if let owner = chat(run.sessionID), sessions.first(where: { $0.id == run.sessionID })?.scheduledOrigin?.runID == id {
            stop(owner)
            for child in owner.transcript.subagents ?? [] where child.isRunning { await stopSubagent(owner, id: child.id) }
            for task in owner.transcript.asyncTasks ?? [] where task.isRunning { await stopAsyncTask(owner, id: task.id) }
        }
        await worker?.value
        if worker == nil { await updateScheduledState(id, .cancelled, detail: "Run cancelled before launch.") }
    }
}
