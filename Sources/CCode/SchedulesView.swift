import SwiftUI
import AppKit
import CCodeCore

struct SchedulesView: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: ScheduledTask?
    @State private var creating = false
    @State private var selectedID: UUID?
    private var tasks: [ScheduledTask] { store.scheduledBook.tasks.filter { !$0.archived } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Routines").font(.title2).fontWeight(.semibold).fixedSize()
                Spacer()
                Button { creating = true } label: { Label("New routine", systemImage: "plus") }.disabled(store.selected != nil && store.localRoutineSource == nil).help("Routines currently run in local workspaces")
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            if let error = store.scheduledError { Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
            HSplitView {
                List(selection: $selectedID) {
                    ForEach(tasks) { task in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(task.name).fontWeight(.medium).lineLimit(1)
                            Text("\(task.active ? task.schedule.title : "Paused") · \(URL(fileURLWithPath: task.projectPath).lastPathComponent)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }.padding(.vertical, 6).tag(task.id)
                    }
                }.frame(minWidth: 210, idealWidth: 250, maxWidth: 290)
                if let task = tasks.first(where: { $0.id == selectedID }) { details(task) }
                else {
                    VStack(spacing: 12) {
                        Image(systemName: "clock").font(.largeTitle).foregroundStyle(.secondary)
                        Text(tasks.isEmpty ? "Make recurring work a routine" : "Choose a routine").font(.headline)
                        Text("Runs use the saved project and agent choices. The app must be running; approvals appear in the owning chat.").foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
                }
            }
        }.frame(width: 780, height: 620).background(Palette.surface)
            .task { await store.loadLocalSchedules(); if selectedID == nil { selectedID = tasks.first?.id } }
            .sheet(isPresented: $creating) { RoutineEditor(store: store, existing: nil) }
            .sheet(item: $editing) { RoutineEditor(store: store, existing: $0) }
    }
    private func action(_ work: @escaping @MainActor () async throws -> Void) {
        Task { do { try await work(); store.scheduledError = nil } catch { store.scheduledError = error.localizedDescription } }
    }
    private func details(_ task: ScheduledTask) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(task.name).font(.title3).fontWeight(.medium).lineLimit(2)
            Text("\(task.schedule.title) · \(task.timezone)").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Run now") { action { _ = try await store.runScheduledTask(task.id, expecting: task.revision) } }
                    .disabled(store.scheduledBook.runs.contains { $0.taskID == task.id && $0.state.isActive })
                Button("Edit") { editing = task }
                Menu {
                    Button(task.active ? "Pause" : "Resume") { action { try await store.setScheduledTaskActive(task.id, active: !task.active) } }
                    Button("Archive routine") { action { try await store.archiveScheduledTask(task.id) } }
                } label: { Image(systemName: "ellipsis") }.fixedSize().accessibilityLabel("Routine options")
            }
            Text(task.instructions).lineLimit(4).textSelection(.enabled)
            Divider()
            Text("Run history").font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(store.scheduledBook.runs.filter { $0.taskID == task.id }.reversed()) { run in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(run.state.title).fontWeight(.medium)
                                Spacer()
                                if store.sessions.contains(where: { $0.id == run.sessionID }) {
                                    Button("Open chat") { Task { await store.select(run.sessionID); dismiss() } }
                                }
                                if run.state.isActive { Button("Cancel") { action { try await store.cancelScheduledRun(run.id) } }.disabled(run.state == .cancelling) }
                            }
                            Text(run.startedAt.formatted(date: .abbreviated, time: .shortened) + (run.catchUp ? " · Missed run" : "")).font(.caption).foregroundStyle(.secondary)
                            if let detail = run.detail { Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        }.padding(12).background(Palette.muted, in: RoundedRectangle(cornerRadius: 9))
                    }
                    if !store.scheduledBook.runs.contains(where: { $0.taskID == task.id }) { Text("No runs yet").foregroundStyle(.secondary) }
                }
            }
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct RoutineEditor: View {
    @Bindable var store: AppStore
    let existing: ScheduledTask?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var instructions = ""
    @State private var path = ""
    @State private var configuration = SessionConfiguration(executable: "", arguments: [])
    @State private var options: [JSONValue] = []
    @State private var modes: JSONValue = [:]
    @State private var models: JSONValue = [:]
    @State private var worktree = false
    @State private var branch = ""
    @State private var frequency = "Manual"
    @State private var time = Date()
    @State private var weekday = 2
    @State private var interval = 60
    @State private var timezone = TimeZone.current.identifier
    @State private var error: String?
    @State private var saving = false
    private let frequencies = ["Manual", "Once", "Hourly", "Daily", "Weekdays", "Weekly", "Interval"]
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(existing == nil ? "New routine" : "Edit routine").font(.title2).fixedSize(); Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(20)
            Divider()
            Form {
                TextField("Name", text: $name)
                Text("Instructions").font(.headline)
                TextEditor(text: $instructions).frame(height: 130).overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.border)).accessibilityLabel("Routine instructions")
                HStack { TextField("Project", text: $path); Button("Choose…", action: chooseFolder) }
                Toggle("Create an isolated worktree", isOn: $worktree)
                TextField("Branch (optional)", text: $branch)
                HStack {
                    Picker("Schedule", selection: $frequency) { ForEach(frequencies, id: \.self) { Text($0) } }
                    if frequency == "Once" { DatePicker("At", selection: $time) }
                    else if ["Hourly", "Daily", "Weekdays", "Weekly"].contains(frequency) { DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute) }
                    if frequency == "Weekly" { Picker("Day", selection: $weekday) { ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) } } }
                    if frequency == "Interval" { TextField("Minutes", value: $interval, format: .number).frame(width: 120) }
                }
                TextField("Timezone", text: $timezone)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Saved agent choices").font(.headline)
                    Text(configuration.executable).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(configuration.executable)
                    ScrollView(.horizontal) { HStack(spacing: 12) {
                        ForEach(options, id: \.["id"]) { option in
                            ConfigMenu(option: configured(option)) { configuration.values[option["id"].string] = $0; configuration.defaultOptionIDs?.remove(option["id"].string) }
                        }
                        if options.isEmpty {
                            LegacyMenu(state: legacyState(modes, model: false), model: false) { if configuration.legacyValues == nil { configuration.legacyValues = [:] }; configuration.legacyValues?["modeId"] = $0 }
                            LegacyMenu(state: legacyState(models, model: true), model: true) { if configuration.legacyValues == nil { configuration.legacyValues = [:] }; configuration.legacyValues?["modelId"] = $0 }
                        }
                        Button("Use agent defaults") { configuration.values = [:]; configuration.legacyValues = nil; configuration.defaultOptionIDs = nil; options = []; modes = [:]; models = [:] }
                    } }
                    Text("Each run keeps these choices even if you change the current chat or app defaults.").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            if let error { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 20) }
            HStack { Text("Local · App must be running").font(.caption).foregroundStyle(.secondary); Spacer(); if saving { ProgressView().controlSize(.small) }; Button("Save", action: save).keyboardShortcut(.defaultAction).disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }.padding(20)
        }.frame(width: 740, height: 680).background(Palette.surface).task { populate() }
    }
    private func configured(_ option: JSONValue) -> JSONValue {
        var result = option
        if let value = configuration.values[option["id"].string] { result["currentValue"] = value }
        return result
    }
    private func legacyState(_ state: JSONValue, model: Bool) -> JSONValue {
        var state = state
        if let value = configuration.legacyValues?[model ? "modelId" : "modeId"] { state[model ? "currentModelId" : "currentModeId"] = .string(value) }
        return state
    }
    private func populate() {
        let localChat = store.localRoutineSource
        if let existing {
            name = existing.name; instructions = existing.instructions; path = existing.projectPath; configuration = existing.configuration; worktree = existing.worktree; branch = existing.branch ?? ""; timezone = existing.timezone
            switch existing.schedule {
            case .manual: frequency = "Manual"
            case .once(let date): frequency = "Once"; time = date
            case .hourly(let minute): frequency = "Hourly"; setTime(hour: 0, minute: minute)
            case .daily(let hour, let minute): frequency = "Daily"; setTime(hour: hour, minute: minute)
            case .weekdays(let hour, let minute): frequency = "Weekdays"; setTime(hour: hour, minute: minute)
            case .weekly(let day, let hour, let minute): frequency = "Weekly"; weekday = day; setTime(hour: hour, minute: minute)
            case .interval(let minutes): frequency = "Interval"; interval = minutes
            }
        } else {
            path = localChat?.workspaceDirectory ?? store.newSessionDraft.projectPath
            configuration = localChat.flatMap { store.confirmedConfiguration($0) } ?? store.newSessionDraft.configuration ?? SessionConfiguration(executable: store.settings.executable, arguments: store.settings.arguments)
            worktree = store.newSessionDraft.worktree
        }
        // A catalog belongs to one launch identity; never offer another agent's options.
        let current = localChat.flatMap { store.confirmedConfiguration($0) } ?? store.newSessionDraft.configuration
        if current?.executable == configuration.executable, current?.arguments == configuration.arguments {
            options = localChat?.transcript.configOptions ?? store.homeConfigOptions
            if options.isEmpty { modes = localChat?.transcript.modes ?? store.homeLegacyState(model: false); models = localChat?.transcript.models ?? store.homeLegacyState(model: true) }
        }
    }
    private func setTime(hour: Int, minute: Int) { time = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date() }
    private func chooseFolder() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; if panel.runModal() == .OK, let url = panel.url { path = url.path } }
    private func save() {
        saving = true; error = nil
        Task {
            defer { saving = false }
            do {
                let clock = Calendar.current.dateComponents([.hour, .minute], from: time), hour = clock.hour ?? 0, minute = clock.minute ?? 0
                let schedule: TaskSchedule
                switch frequency {
                case "Once": schedule = .once(time)
                case "Hourly": schedule = .hourly(minute: minute)
                case "Daily": schedule = .daily(hour: hour, minute: minute)
                case "Weekdays": schedule = .weekdays(hour: hour, minute: minute)
                case "Weekly": schedule = .weekly(day: weekday, hour: hour, minute: minute)
                case "Interval": schedule = .interval(minutes: interval)
                default: schedule = .manual
                }
                var task = try existing ?? ScheduledTask(name: name, instructions: instructions, projectPath: path, configuration: configuration)
                task.name = name; task.instructions = instructions; task.projectPath = path; task.configuration = configuration; task.worktree = worktree; task.branch = branch.isEmpty ? nil : branch; task.schedule = schedule; task.timezone = timezone
                try await store.saveScheduledTask(task, expecting: existing?.revision); dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
