import SwiftUI
import AppKit
import CCodeCore

struct NewSessionHome: View {
    @Bindable var store: AppStore
    @State private var branch = ""
    @State private var branches: [String] = []
    @State private var newBranchName = ""
    @State private var contextRequest: UUID?
    @FocusState private var focusNewBranch: Bool
    private var projects: [String] { Array(Set(store.sessions.filter { $0.environment.isLocal }.map(\.projectGroupingPath))).sorted() }
    private var greeting: String {
        NSFullUserName().split(separator: " ").first.map { "Welcome back, \($0)" } ?? "Welcome back"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 10) {
                Image(systemName: "asterisk").font(.system(size: 22, weight: .medium)).foregroundStyle(Palette.accent)
                Text(greeting).font(.system(size: 20, weight: .medium))
            }.padding(.top, 80)
            if !store.attentionSessions.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Sessions").font(.system(size: 15, weight: .medium))
                    ScrollView {
                        LazyVStack(spacing: 10) { ForEach(store.attentionSessions) { info in attention(info) } }
                    }.frame(maxHeight: 180)
                }.padding(.top, 18)
            }
            Spacer(minLength: 32)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Menu {
                        Text("Local").disabled(true)
                        Menu("SSH") {
                            ForEach(store.settings.sshConnections ?? []) { preset in
                                Button(preset.host.name) { store.selectedSSHPresetID = preset.id; store.showSSHWorkspaces = true }
                            }
                            Divider()
                            Button("Add SSH connection…") { store.selectedSSHPresetID = nil; store.showSSHWorkspaces = true }
                        }
                    } label: { Label("Local", systemImage: "laptopcomputer") }.menuStyle(.borderlessButton).fixedSize().padding(8).background(Palette.muted, in: RoundedRectangle(cornerRadius: 7)).accessibilityLabel("Execution environment")
                    Menu {
                        ForEach(projects, id: \.self) { path in Button(path) { store.newSessionDraft.projectPath = path } }
                        if !projects.isEmpty { Divider() }
                        Button("Choose folder…") { store.chooseNewSessionProject() }
                    } label: { Label(store.newSessionDraft.projectPath.isEmpty ? "Choose project" : URL(fileURLWithPath: store.newSessionDraft.projectPath).lastPathComponent, systemImage: "folder") }
                        .menuStyle(.borderlessButton).fixedSize().padding(8).background(Palette.muted, in: RoundedRectangle(cornerRadius: 7))
                    if !branch.isEmpty || !branches.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.branch")
                            BranchPicker(selection: $store.newSessionDraft.branch, current: branch.isEmpty ? "Detached HEAD" : branch, branches: branches).frame(width: 160, height: 24).disabled(store.changingBranch)
                            Button { if !store.changingBranch { newBranchName = ""; store.showNewBranch = true } } label: { Image(systemName: "plus") }
                                .buttonStyle(.plain).help("Create branch").accessibilityLabel("Create branch")
                                .popover(isPresented: $store.showNewBranch) {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text("New branch").font(.headline)
                                        Text("From \(store.newSessionDraft.branch ?? (branch.isEmpty ? "HEAD" : branch))").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                        TextField("Branch name", text: $newBranchName).textFieldStyle(.roundedBorder).focused($focusNewBranch).accessibilityLabel("New branch name").onSubmit(createBranch).disabled(store.changingBranch)
                                        HStack {
                                            Button("Cancel") { store.cancelHomeBranch() }.keyboardShortcut(.cancelAction)
                                            Spacer()
                                            if store.changingBranch { ProgressView().controlSize(.small) }
                                            Button("Create", action: createBranch).keyboardShortcut(.defaultAction).disabled(newBranchName.isEmpty || store.changingBranch)
                                        }
                                    }.padding(16).frame(width: 300)
                                        .task { focusNewBranch = true }
                                }
                        }.padding(6).background(Palette.muted, in: RoundedRectangle(cornerRadius: 7))
                    }
                    Toggle("worktree", isOn: $store.newSessionDraft.worktree).toggleStyle(.checkbox).help("Work in an isolated copy of the Git repository")
                    Spacer(minLength: 0)
                }.font(.system(size: 12))
                HStack {
                    TextField("Project folder", text: $store.newSessionDraft.projectPath).textFieldStyle(.plain).font(.system(size: 12)).accessibilityLabel("Project folder")
                    Button("Choose…") { store.chooseNewSessionProject() }
                }.foregroundStyle(.secondary).padding(.horizontal, 10)
                if let folders = store.newSessionDraft.additionalDirectories, !folders.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(folders, id: \.self) { path in
                                HStack {
                                    Label(path, systemImage: "folder").lineLimit(1).truncationMode(.middle).help(path)
                                    Spacer(minLength: 0)
                                    Button { store.removeHomeFolder(path) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Remove folder \(path)")
                                }
                            }
                        }
                    }.frame(height: min(100, CGFloat(folders.count) * 24)).font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 10)
                }
                Button { store.chooseAdditionalSessionFolders() } label: { Label("Add another folder", systemImage: "plus") }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 10).disabled(store.newSessionDraft.projectPath.isEmpty)
                if let attachments = store.newSessionDraft.attachments, !attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) { HStack {
                        ForEach(attachments) { attachment in
                            AttachmentChip(attachment: attachment, url: store.attachmentURL(attachment), disabled: store.startingSession) { store.removeHomeAttachment(attachment) }
                        }
                    } }
                }
                if store.homeAttachingFiles {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading files…"); Button("Cancel") { store.cancelHomeAttachmentImports() } }.font(.caption).foregroundStyle(.secondary)
                }
                DictationPreview(capture: store.dictation, destination: .home, draft: $store.newSessionDraft.text)
                HStack(alignment: .bottom, spacing: 8) {
                    ContextPromptEditor(text: $store.newSessionDraft.text, workspace: store.homeWorkspace, commands: [],
                        attach: { candidate, query in await store.attachHomeContext(candidate, replacing: query) }, send: start, cancel: {
                            store.cancelHomeAttachmentImports()
                            if let chat = store.selected { store.stop(chat) } else { Task { await store.cancelHomeDiscovery() } }
                        }, contextRequest: contextRequest, attachmentInput: { store.attachHomeInputs($0) }, attachmentError: { store.error = $0 },
                        placeholder: "Describe a task or ask a question", focusOnMount: true)
                        .id(store.homeWorkspace?.roots)
                    Button(action: start) { Image(systemName: "return").font(.system(size: 15)).frame(width: 30, height: 30) }
                        .buttonStyle(.plain).disabled(store.showNewBranch || store.changingBranch || store.startingSession || store.discoveringHomeOptions || store.homeAttachingFiles || store.newSessionDraft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && store.newSessionDraft.attachments?.isEmpty != false).help("Send (Enter)").accessibilityLabel("Send").padding(.bottom, 10)
                }.padding(.leading, 6).padding(.trailing, 12).background(Palette.surface, in: RoundedRectangle(cornerRadius: 13)).overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.13), lineWidth: 1) }
                    .onDrop(of: [.fileURL, .image], isTargeted: nil) { store.attachHomeProviders($0) }
                HStack {
                    Button { store.attachHomeFiles() } label: { Image(systemName: "plus") }.help("Attach files").accessibilityLabel("Attach files")
                    DictationButton(capture: store.dictation, destination: .home)
                    Button { contextRequest = UUID() } label: { Image(systemName: "at") }.help("Attach project context (@)").accessibilityLabel("Attach project context")
                    if store.homeConfigurationOptions.isEmpty, store.homeLegacyState(model: false)["availableModes"].array.isEmpty, store.homeLegacyState(model: true)["availableModels"].array.isEmpty { Button("Customize agent") { store.showSettings = true } }
                    LegacyMenu(state: store.homeLegacyState(model: false), model: false, disabled: store.discoveringHomeOptions) { store.chooseHomeLegacy(model: false, id: $0) }
                    ForEach(store.homeConfigurationOptions.filter { $0["category"].string == "mode" }, id: \.["id"]) { option in
                        ConfigMenu(option: option, disabled: store.discoveringHomeOptions) { store.chooseHomeConfiguration(id: option["id"].string, value: $0) }
                    }
                    Spacer()
                    LegacyMenu(state: store.homeLegacyState(model: true), model: true, disabled: store.discoveringHomeOptions) { store.chooseHomeLegacy(model: true, id: $0) }
                    ForEach(store.homeConfigurationOptions.filter { $0["category"].string != "mode" }, id: \.["id"]) { option in
                        ConfigMenu(option: option, disabled: store.discoveringHomeOptions) { store.chooseHomeConfiguration(id: option["id"].string, value: $0) }
                    }
                    if store.discoveringHomeOptions {
                        ProgressView().controlSize(.small)
                        Text("Loading agent options…")
                        Button("Cancel") { Task { await store.cancelHomeDiscovery() } }
                    } else {
                        Button { Task { await store.refreshHomeConfiguration(force: true) } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh agent options").accessibilityLabel("Refresh agent options")
                    }
                    if store.startingSession { ProgressView().controlSize(.small) }
                }.font(.system(size: 12)).foregroundStyle(.secondary).buttonStyle(.plain).padding(.horizontal, 10)
                if let error = store.homeDiscoveryError {
                    Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled).lineLimit(3).padding(.horizontal, 10)
                    HStack { ForEach(store.homeAuthMethods, id: \.["id"]) { method in
                        Button(method["name"].string) { Task { await store.refreshHomeConfiguration(force: true, authentication: method["id"].string) } }.disabled(store.discoveringHomeOptions)
                    } }.padding(.horizontal, 10)
                }
            }.disabled(store.startingSession)
        }.frame(maxWidth: 780).padding(.horizontal, 26).padding(.bottom, 18).frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            if !store.showSidebar { Button { store.showSidebar = true } label: { Image(systemName: "sidebar.left") }.buttonStyle(.plain).help("Show sidebar").padding(.leading, 85).padding(.top, 16) }
        }
        .task(id: store.settings) { await store.refreshHomeConfiguration() }
        .onChange(of: store.newSessionDraft.projectPath) { _, _ in store.cancelHomeBranch() }
        .onChange(of: store.showNewBranch) { _, shown in if !shown { store.cancelHomeBranch() } }
        .onDisappear { store.cancelHomeBranch() }
        .task(id: store.newSessionDraft.projectPath) {
            let path = store.newSessionDraft.projectPath
            branch = ""; branches = []
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            if !path.isEmpty {
                async let options = try? Repository.branches(at: path)
                let name = (try? await Repository.run(["symbolic-ref", "--short", "HEAD"], at: path))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let available = await options ?? []
                guard !Task.isCancelled else { return }; branch = name; branches = available
            }
            await store.refreshHomeConfiguration()
        }
    }
    private func start() { Task { await store.startFromHome() } }
    private func createBranch() {
        let name = newBranchName, path = store.newSessionDraft.projectPath
        Task {
            if await store.createHomeBranch(name), store.newSessionDraft.projectPath == path {
                if !branches.contains(name) { branches.append(name); branches.sort() }
                store.showNewBranch = false
            }
        }
    }
    private func attention(_ info: SessionInfo) -> some View {
        HStack(spacing: 10) {
            Button { Task { await store.select(info.id) } } label: {
                HStack(spacing: 10) {
                    Circle().fill(Color.orange).frame(width: 5, height: 5)
                    Text(store.sessionActivity(info.id) == .completed ? "Finished" : store.chat(info.id)?.hasPendingDecisions == true ? "Needs input" : "Needs attention").foregroundStyle(.orange)
                    Text(info.title).lineLimit(1)
                    if let error = info.lastError { Text(error).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer(minLength: 0)
                    Text(info.projectName).foregroundStyle(.secondary).lineLimit(1)
                    Text(info.updatedAt.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))).foregroundStyle(.tertiary)
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { store.dismissAttention(info.id) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Dismiss session").accessibilityLabel("Dismiss \(info.title)")
        }.font(.system(size: 13)).padding(12).background(Palette.muted, in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct BranchPicker: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var selection: String?
    let current: String
    let branches: [String]
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSComboBox {
        let view = NSComboBox(); view.delegate = context.coordinator
        view.completes = true; view.numberOfVisibleItems = 12
        view.font = .systemFont(ofSize: 12); view.controlSize = .small
        view.setAccessibilityLabel("Session branch")
        return view
    }
    func updateNSView(_ view: NSComboBox, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.options != branches {
            view.removeAllItems(); view.addItems(withObjectValues: branches)
            context.coordinator.options = branches
        }
        let value = selection ?? current
        if view.stringValue != value { view.stringValue = value }
        view.isEnabled = isEnabled
    }
    final class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: BranchPicker
        var options: [String] = []
        init(_ parent: BranchPicker) { self.parent = parent }
        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSComboBox, options.indices.contains(view.indexOfSelectedItem) else { return }
            parent.selection = options[view.indexOfSelectedItem]
        }
        func controlTextDidChange(_ notification: Notification) {
            if let view = notification.object as? NSComboBox { parent.selection = view.stringValue }
        }
    }
}
