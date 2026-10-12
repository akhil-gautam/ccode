import Foundation
import XCTest
import SwiftUI
import AppKit
@testable import CCodeCore
@testable import CCode

final class ScheduledTaskTests: XCTestCase, @unchecked Sendable {
    func testCalendarRecurrencesRespectTimezoneWeekendsAndDST() throws {
        let daily = TaskSchedule.daily(hour: 9, minute: 0)
        XCTAssertEqual(try daily.latest(onOrBefore: date("2026-10-07T04:00:00Z"), timezone: "Asia/Kolkata", anchor: date("2026-10-01T00:00:00Z")), date("2026-10-07T03:30:00Z"))
        let weekdays = TaskSchedule.weekdays(hour: 9, minute: 0)
        XCTAssertEqual(try weekdays.latest(onOrBefore: date("2026-10-11T12:00:00Z"), timezone: "UTC", anchor: date("2026-10-01T00:00:00Z")), date("2026-10-09T09:00:00Z"))
        let weekly = TaskSchedule.weekly(day: 2, hour: 9, minute: 0)
        XCTAssertEqual(try weekly.latest(onOrBefore: date("2026-10-07T12:00:00Z"), timezone: "UTC", anchor: date("2026-10-01T00:00:00Z")), date("2026-10-05T09:00:00Z"))
        let repeated = TaskSchedule.daily(hour: 1, minute: 30)
        XCTAssertEqual(try repeated.latest(onOrBefore: date("2026-11-01T10:00:00Z"), timezone: "America/Los_Angeles", anchor: date("2026-10-01T00:00:00Z")), date("2026-11-01T08:30:00Z"))
        XCTAssertEqual(try TaskSchedule.daily(hour: 2, minute: 30).latest(onOrBefore: date("2026-03-08T11:00:00Z"), timezone: "America/Los_Angeles", anchor: date("2026-03-01T00:00:00Z")), date("2026-03-08T10:00:00Z"))
        XCTAssertEqual(try TaskSchedule.hourly(minute: 30).latest(onOrBefore: date("2026-11-01T10:00:00Z"), timezone: "America/Los_Angeles", anchor: date("2026-10-01T00:00:00Z")), date("2026-11-01T08:30:00Z"))
        XCTAssertNil(try TaskSchedule.manual.latest(onOrBefore: Date(), timezone: "UTC", anchor: Date()))
        XCTAssertThrowsError(try daily.latest(onOrBefore: Date(), timezone: "Bad/Zone", anchor: Date()))
    }

    func testDurableSlotClaimsCatchUpOnceAndNeverOverlap() async throws {
        let root = try temporary(), storage = SessionStorage(directory: root.appendingPathComponent("data")), created = date("2026-10-01T00:00:00Z")
        let task = try recipe(root: root, at: created, schedule: .daily(hour: 9, minute: 0))
        _ = try await storage.saveScheduledTask(task, expecting: nil)
        let now = date("2026-10-07T12:00:00Z")
        let first = try await storage.claimDueScheduledRuns(at: now, busyTasks: [])
        XCTAssertEqual(first.count, 1); XCTAssertEqual(first[0].run.scheduledAt, date("2026-10-07T09:00:00Z")); XCTAssertTrue(first[0].run.catchUp)
        let again = try await storage.claimDueScheduledRuns(at: now, busyTasks: []); XCTAssertTrue(again.isEmpty)
        let tomorrow = try await storage.claimDueScheduledRuns(at: date("2026-10-08T12:00:00Z"), busyTasks: [])
        XCTAssertTrue(tomorrow.isEmpty)
        let book = try await storage.loadScheduledBook()
        XCTAssertEqual(book.runs.last?.state, .skipped)
        XCTAssertTrue(book.runs.last?.detail?.contains("previous") == true)
    }

    func testPauseResumeManualAndRestartDoNotReplayUnknownRuns() async throws {
        let root = try temporary(), storage = SessionStorage(directory: root.appendingPathComponent("data")), created = date("2026-10-01T00:00:00Z")
        let task = try recipe(root: root, at: created, schedule: .hourly(minute: 0))
        _ = try await storage.saveScheduledTask(task, expecting: nil)
        _ = try await storage.setScheduledTaskActive(task.id, active: false, at: created)
        let paused = try await storage.claimDueScheduledRuns(at: date("2026-10-02T12:00:00Z"), busyTasks: []); XCTAssertTrue(paused.isEmpty)
        let manual = try await storage.claimManualScheduledRun(task.id, expecting: nil, at: date("2026-10-02T12:00:00Z"), busyTasks: [])
        XCTAssertEqual(manual.task.instructions, task.instructions)
        let restarted = SessionStorage(directory: root.appendingPathComponent("data"))
        let recovered = try await restarted.recoverScheduledRuns(at: date("2026-10-02T13:00:00Z"))
        XCTAssertEqual(recovered.runs.first?.state, .interrupted)
        _ = try await restarted.setScheduledTaskActive(task.id, active: true, at: date("2026-10-02T13:15:00Z"))
        let resumed = try await restarted.claimDueScheduledRuns(at: date("2026-10-02T13:30:00Z"), busyTasks: []); XCTAssertTrue(resumed.isEmpty)
        let next = try await restarted.claimDueScheduledRuns(at: date("2026-10-02T14:01:00Z"), busyTasks: []); XCTAssertEqual(next.count, 1)
    }

    func testEditedTaskDoesNotChangeClaimSnapshotAndStaleEditorRefuses() async throws {
        let root = try temporary(), storage = SessionStorage(directory: root.appendingPathComponent("data")), task = try recipe(root: root, at: Date(), schedule: .manual)
        _ = try await storage.saveScheduledTask(task, expecting: nil)
        let claim = try await storage.claimManualScheduledRun(task.id, expecting: task.revision, at: Date(), busyTasks: [])
        var edit = task; edit.instructions = "Future instructions"
        let book = try await storage.saveScheduledTask(edit, expecting: task.revision)
        XCTAssertEqual(claim.task.instructions, "Scheduled fixture work")
        XCTAssertEqual(book.tasks.first?.instructions, "Future instructions")
        do { _ = try await storage.saveScheduledTask(task, expecting: task.revision); XCTFail("Stale editor overwrote task") } catch { }
        let finished = try await storage.updateScheduledRun(claim.run.id, state: .completed, detail: nil, at: Date())
        XCTAssertEqual(finished.tasks.first?.instructions, "Future instructions")
        XCTAssertEqual(finished.runs.first?.taskRevision, task.revision)
    }

    func testStorageFailureInvalidTasksAndConcurrencyLimitNeverLaunch() async throws {
        let root = try temporary(), blocker = root.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: blocker)
        let invalid = SessionStorage(directory: blocker), task = try recipe(root: root, at: Date(), schedule: .manual)
        do { _ = try await invalid.saveScheduledTask(task, expecting: nil); XCTFail("Storage failure was hidden") } catch { }
        XCTAssertThrowsError(try ScheduledTask(name: "empty", instructions: "", projectPath: root.path, configuration: task.configuration))
        XCTAssertThrowsError(try ScheduledTask(name: "bad", instructions: "work", projectPath: "relative", configuration: task.configuration))
        let storage = SessionStorage(directory: root.appendingPathComponent("data"))
        for i in 0..<4 {
            var next = try recipe(root: root, at: date("2026-10-01T00:00:00Z"), schedule: .daily(hour: 9, minute: 0)); next.name = "task-\(i)"
            _ = try await storage.saveScheduledTask(next, expecting: nil)
        }
        let claims = try await storage.claimDueScheduledRuns(at: date("2026-10-02T09:01:00Z"), busyTasks: [], limit: 2)
        XCTAssertEqual(claims.count, 2)
        let book = try await storage.loadScheduledBook(); XCTAssertEqual(book.runs.filter { $0.state == .skipped }.count, 2)
    }

    func testOversizedBookSaveLeavesPreviousReadableState() async throws {
        let root = try temporary(), storage = SessionStorage(directory: root.appendingPathComponent("data")), now = Date()
        var book = ScheduledBook()
        for i in 0..<68 {
            var configuration = SessionConfiguration(executable: "/usr/bin/python3", arguments: [])
            configuration.values["large"] = .string(String(repeating: "a", count: 126000))
            book.tasks.append(try ScheduledTask(name: "task-\(i)", instructions: String(repeating: "x", count: 64000), projectPath: root.path, configuration: configuration, createdAt: now))
        }
        // Seed a valid, readable book near the aggregate limit. Individual
        // recipe limits must not allow the next edit to make it unreadable.
        let directory = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        book.tasks.removeLast(3)
        try JSONEncoder().encode(book).write(to: directory.appendingPathComponent("routines.json"))
        let extra = try ScheduledTask(name: "extra", instructions: String(repeating: "x", count: 64000), projectPath: root.path, configuration: book.tasks[0].configuration)
        var refused = false
        for index in 0..<4 {
            let next = try ScheduledTask(name: "extra-\(index)", instructions: extra.instructions, projectPath: root.path, configuration: extra.configuration)
            do { _ = try await storage.saveScheduledTask(next, expecting: nil) }
            catch { refused = true; break }
            // Next iteration needs a distinct identity as well.
            book = try await storage.loadScheduledBook()
        }
        XCTAssertTrue(refused, "Aggregate oversized save must be rejected")
        _ = try await storage.loadScheduledBook()
    }

    @MainActor func testRunNowUsesCapturedAgentAndPreservesCurrentChatAndHomeDraft() async throws {
        let root = try temporary(), store = AppStore(directory: root.appendingPathComponent("data"))
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures"))
        store.settings.executable = "/usr/bin/python3"; store.settings.arguments = [fixture.path]
        await store.create(path: root.path, worktree: false)
        let existing = try XCTUnwrap(store.selected); existing.draft = "Unrelated composer"
        store.newSessionDraft.text = "Unrelated Home"
        let task = try recipe(root: root, at: Date(), schedule: .manual, arguments: [fixture.path])
        try await store.saveScheduledTask(task, expecting: nil)
        store.settings.executable = "/not-the-captured-agent"
        let runID = try await store.runScheduledTask(task.id)
        try await wait(store, id: runID, state: .needsApproval)
        let run = try XCTUnwrap(store.scheduledBook.runs.first { $0.id == runID }), chat = try XCTUnwrap(store.chat(run.sessionID))
        XCTAssertEqual(store.selectedID, existing.id); XCTAssertEqual(existing.draft, "Unrelated composer"); XCTAssertEqual(store.newSessionDraft.text, "Unrelated Home")
        XCTAssertEqual(store.sessions.first { $0.id == chat.id }?.scheduledOrigin?.runID, runID)
        let approval = try XCTUnwrap(chat.approvals.first)
        store.resolveApproval(chat, id: approval.id, option: "allow")
        try await wait(store, id: runID, state: .completed)
        XCTAssertEqual(chat.transcript.items.first { $0.kind == "user" }?.text, task.instructions)
        XCTAssertEqual(store.selectedID, existing.id)
        await store.shutdown()
    }

    @MainActor func testCancelRoutineReleasesOnlyItsOwnApprovalAndRetainsHistory() async throws {
        let root = try temporary(), store = AppStore(directory: root.appendingPathComponent("data")), fixture = try XCTUnwrap(Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures"))
        store.settings.executable = "/usr/bin/python3"; store.settings.arguments = [fixture.path]
        let a = try recipe(root: root, at: Date(), schedule: .manual, arguments: [fixture.path]); var b = try recipe(root: root, at: Date(), schedule: .manual, arguments: [fixture.path]); b.name = "second"
        try await store.saveScheduledTask(a, expecting: nil); try await store.saveScheduledTask(b, expecting: nil)
        let first = try await store.runScheduledTask(a.id), second = try await store.runScheduledTask(b.id)
        try await wait(store, id: first, state: .needsApproval); try await wait(store, id: second, state: .needsApproval)
        try await store.cancelScheduledRun(first)
        try await wait(store, id: first, state: .cancelled)
        let sibling = try XCTUnwrap(store.scheduledBook.runs.first { $0.id == second }).sessionID
        XCTAssertEqual(store.chat(sibling)?.approvals.count, 1)
        XCTAssertNotNil(store.sessions.first { $0.id == first })
        await store.shutdown()
    }

    @MainActor func testStoppingOwningChatDoesNotMarkScheduledRunCompleted() async throws {
        let root = try temporary(), store = AppStore(directory: root.appendingPathComponent("data")), fixture = try XCTUnwrap(Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures"))
        store.settings.executable = "/usr/bin/python3"; store.settings.arguments = [fixture.path]
        let task = try recipe(root: root, at: Date(), schedule: .manual, arguments: [fixture.path])
        try await store.saveScheduledTask(task, expecting: nil)
        let id = try await store.runScheduledTask(task.id)
        try await wait(store, id: id, state: .needsApproval)
        store.stop(try XCTUnwrap(store.chat(id)))
        let deadline = ContinuousClock.now + .seconds(15)
        while store.scheduledBook.runs.first(where: { $0.id == id })?.state.isActive == true {
            guard ContinuousClock.now < deadline else { throw ACPError.timeout("Stopped schedule") }
            try await Task.sleep(for: .milliseconds(10))
        }
        let state = store.scheduledBook.runs.first(where: { $0.id == id })?.state
        XCTAssertTrue(state == .cancelled || state == .interrupted, "Stopped work was labeled \(String(describing: state))")
        await store.shutdown()
    }

    @MainActor func testRoutineManagerFitsLightAndDarkWithoutCompressedHeader() async throws {
        let root = try temporary(), store = AppStore(directory: root.appendingPathComponent("data"))
        for scheme in [ColorScheme.light, .dark] {
            let view = NSHostingView(rootView: SchedulesView(store: store).preferredColorScheme(scheme))
            view.frame = NSRect(x: 0, y: 0, width: 780, height: 620); view.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(view.fittingSize.width, 800); XCTAssertLessThanOrEqual(view.fittingSize.height, 650)
        }
        await store.shutdown()
    }

    private func recipe(root: URL, at now: Date, schedule: TaskSchedule, arguments: [String] = []) throws -> ScheduledTask {
        try ScheduledTask(name: "fixture", instructions: "Scheduled fixture work", projectPath: root.path, configuration: SessionConfiguration(executable: "/usr/bin/python3", arguments: arguments), schedule: schedule, timezone: "UTC", createdAt: now)
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-schedule-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    @MainActor private func wait(_ store: AppStore, id: UUID, state: ScheduledRunState) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while store.scheduledBook.runs.first(where: { $0.id == id })?.state != state {
            guard ContinuousClock.now < deadline else { throw ACPError.timeout("Scheduled state \(state)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
