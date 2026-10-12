import SwiftUI
import Observation
import AppKit
import CCodeCore

@MainActor @Observable final class ExtensionsModel {
    let configuration: AgentConfiguration
    var document: ConfigurationDocument?
    var text = ""
    var dirty: Bool { text != document?.text }
    var saving = false
    var failure: String?
    var notice: String?
    var cliOutput = ""
    var operating = false
    var liveServers: [MCPServerConnection] = []
    var pluginReview: PluginInstallReview?
    @ObservationIgnored private var pluginReviewRevision = UUID()
    func acceptPluginReview(agent: AgentSettings) {
        guard let review = pluginReview else { return }
        installPlugin(agent: agent, name: review.plugin, scope: review.scope, accepting: review)
    }
    func dismissPluginReview() {
        pluginReviewRevision = UUID()
        if let review = pluginReview { pluginReview = nil; Task { await configuration.discardPluginInstallationReview(review) } }
    }
    private func installPlugin(agent: AgentSettings, name: String, scope: ConfigurationScope, accepting: PluginInstallReview? = nil) {
        guard !operating else { return }
        let previous = pluginReview, revision = UUID()
        pluginReviewRevision = revision; pluginReview = nil
        operating = true; failure = nil; notice = nil; cliOutput = ""
        operation = Task {
            defer { operating = false; operation = nil }
            if let previous, previous.id != accepting?.id { await configuration.discardPluginInstallationReview(previous) }
            do {
                let result: PluginInstallationResult
                if let accepting { result = try await configuration.acceptPluginInstallation(accepting, executable: agent.executable, arguments: agent.arguments) }
                else { result = try await configuration.installPlugin(executable: agent.executable, arguments: agent.arguments, name: name, scope: scope) }
                guard !Task.isCancelled, pluginReviewRevision == revision else {
                    if case .review(let review) = result { await configuration.discardPluginInstallationReview(review) }
                    throw CancellationError()
                }
                switch result {
                case .installed: notice = "Plugin installed. Reload plugins in this agent to apply it."
                case .review(let review): pluginReview = review; notice = accepting == nil ? "Review the install command before running it." : "The command or marketplace changed. Review the current command before installing."
                }
            } catch {
                if let accepting { await configuration.discardPluginInstallationReview(accepting) }
                failure = error is CancellationError ? "Stopped. The installation may already have applied changes. Refresh installed plugins before repeating it." : error.localizedDescription
            }
        }
    }
    var authentication: MCPAuthentication?
    func authenticate(store: AppStore, chat: ChatSession, name: String) {
        guard !operating else { return }
        operating = true; failure = nil; notice = nil
        let generation = chat.connectionGeneration
        operation = Task {
            var flow: MCPAuthentication?
            do {
                var result = try await store.performLiveConfiguration(chat, operation: .beginAuthentication(name: name))
                let deadline = ContinuousClock.now + .seconds(600)
                while true {
                    // Capture receipt before checking cancellation so a completed
                    // Begin can still be explicitly released when the view closes.
                    flow = result.authentication
                    try Task.checkCancellation()
                    guard store.selected === chat, chat.connectionGeneration == generation, let current = flow else { throw CancellationError() }
                    liveServers = result.servers; authentication = current
                    switch current.state {
                    case .connected: notice = "Signed in to \(name)."
                    case .failed: throw ACPError.workspace("Claude could not authenticate this server. Refresh its status before trying again.")
                    case .cancelled: throw CancellationError()
                    case .pending:
                        guard ContinuousClock.now < deadline else { throw ACPError.workspace("Sign-in timed out. Refresh the server status before trying again.") }
                        try await Task.sleep(for: .seconds(1))
                        guard store.selected === chat, chat.connectionGeneration == generation else { throw CancellationError() }
                        result = try await store.performLiveConfiguration(chat, operation: .authenticationStatus(name: name, flowID: current.id))
                        continue
                    }
                    break
                }
            } catch {
                failure = error is CancellationError ? "Sign-in tracking stopped. Claude owns the browser callback; credentials already issued are not revoked." : error.localizedDescription
            }
            authentication = nil
            if let flow, chat.connectionGeneration == generation, chat.connection != nil {
                // Separate, owned store request: the caller's cancellation must
                // not prevent releasing transient authentication tracking.
                let cleanup = Task { @MainActor in
                    _ = try? await store.performLiveConfiguration(chat, operation: .cancelAuthentication(name: name, flowID: flow.id))
                }
                await cleanup.value
            }
            operating = false; operation = nil
        }
    }
    func invokeLive(store: AppStore, chat: ChatSession, operation value: LiveConfigurationOperation) {
        guard !operating else { return }
        operating = true; failure = nil; notice = nil
        operation = Task {
            defer { operating = false; operation = nil }
            do {
                let result = try await store.performLiveConfiguration(chat, operation: value)
                try Task.checkCancellation(); guard store.selected === chat else { throw CancellationError() }
                liveServers = result.servers
                notice = value.mutating ? "Applied to this agent session." + (result.errorCount > 0 ? " Claude reported \(result.errorCount) extension errors." : "") : "Live status refreshed."
            } catch { failure = error is CancellationError ? "Stopped. A server or extension change may already have applied. Refresh its live status before repeating it; queued work stays paused after an unconfirmed change." : error.localizedDescription }
        }
    }
    @ObservationIgnored private var drafts: [String: (ConfigurationDocument, String)] = [:]
    @ObservationIgnored private var selection = UUID()
    @ObservationIgnored private var operation: Task<Void, Never>?
    init(configuration: AgentConfiguration) { self.configuration = configuration }
    private func key(_ scope: ConfigurationScope, _ kind: ConfigurationDocumentKind) -> String { scope.rawValue + "/" + kind.rawValue }
    func select(scope: ConfigurationScope, kind: ConfigurationDocumentKind, reload: Bool = false) async throws {
        if let document { drafts[key(document.scope, document.kind)] = (document, text) }
        let identity = UUID(); selection = identity
        let selectedKey = key(scope, kind)
        let value: (ConfigurationDocument, String)
        if !reload, let draft = drafts[selectedKey] { value = draft }
        else { let record = try await configuration.document(scope: scope, kind: kind); value = (record, record.text) }
        try Task.checkCancellation(); guard selection == identity else { throw CancellationError() }
        document = value.0; text = value.1; failure = nil; notice = nil
    }
    func save() async throws {
        guard !saving, let original = document else { throw ACPError.workspace("Open a configuration file first.") }
        saving = true; defer { saving = false }
        let contents = text
        do {
            let saved = try await configuration.save(original, text: contents)
            drafts[key(saved.scope, saved.kind)] = (saved, saved.text)
            if document?.id == original.id { document = saved; if text == contents { text = saved.text } }
            failure = nil; notice = "Saved. Reload or reconnect the agent to apply extension changes."
        } catch { failure = error.localizedDescription; throw error }
    }
    func invoke(agent: AgentSettings, operation value: ConfigurationOperation) {
        if case .installPlugin(let name, let scope) = value { installPlugin(agent: agent, name: name, scope: scope); return }
        guard !operating else { return }
        dismissPluginReview()
        operating = true; failure = nil; notice = nil
        operation = Task {
            defer { operating = false; operation = nil }
            do { cliOutput = try await configuration.invoke(executable: agent.executable, arguments: agent.arguments, operation: value) }
            catch { failure = error is CancellationError ? "Cancelled. A configuration command may have applied changes before stopping; refresh to check." : error.localizedDescription }
        }
    }
    func cancel() { operation?.cancel(); dismissPluginReview() }
}
struct ConfigurationEditor: View {
    @Bindable var model: ExtensionsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let document = model.document {
                HStack(spacing: 12) {
                    Label(document.scope.title, systemImage: document.editable ? "doc.text" : "lock").fixedSize()
                    Text(document.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer(minLength: 0)
                    if model.dirty { Text("Unsaved").font(.caption).foregroundStyle(.secondary).fixedSize() }
                }
                if !document.editable { Text("Your organization manages this file. It is read-only.").font(.caption).foregroundStyle(.secondary) }
                TextEditor(text: $model.text).font(.system(size: 12, design: .monospaced)).disabled(!document.editable || model.saving)
                    .padding(6).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8)).overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)) }
                    .accessibilityLabel("\(document.scope.title) \(document.kind.rawValue) editor")
                HStack {
                    Button(model.dirty ? "Discard draft and reload" : "Reload file") { Task { do { try await model.select(scope: document.scope, kind: document.kind, reload: true) } catch { model.failure = error.localizedDescription } } }.disabled(model.saving)
                    Spacer()
                    if model.saving { ProgressView().controlSize(.small) }
                    Button("Save") { Task { try? await model.save() } }.buttonStyle(.borderedProminent).disabled(!document.editable || !model.dirty || model.saving)
                }
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            if let failure = model.failure { Text(failure).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
        }.padding(16)
    }
}

private enum ExtensionSection: String, CaseIterable, Identifiable {
    case settings = "Settings", instructions = "Instructions", hooks = "Hooks", mcp = "MCP servers", skills = "Skills & commands", plugins = "Plugins", effective = "Effective configuration"
    var id: String { rawValue }
    var icon: String { switch self { case .settings: "slider.horizontal.3"; case .instructions: "doc.text"; case .hooks: "arrow.triangle.branch"; case .mcp: "point.3.connected.trianglepath.dotted"; case .skills: "book"; case .plugins: "puzzlepiece.extension"; case .effective: "checklist" } }
}

struct ExtensionsView: View {
    let store: AppStore
    let project: String
    @State private var model: ExtensionsModel?
    @State private var section = ExtensionSection.settings
    @State private var scope = ConfigurationScope.project
    @State private var failure: String?
    @State private var records: [ConfigurationExtension] = []
    @State private var effective = ""
    @State private var serverName = ""
    @State private var serverJSON = "{\n  \"type\": \"http\",\n  \"url\": \"http://127.0.0.1:3000/mcp\"\n}"
    @State private var pluginName = ""
    @State private var marketplace = ""
    @State private var reloading = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) { Text("Customize Claude").font(.title2.weight(.medium)); Text(project).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                Spacer(minLength: 12)
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Close customization")
            }.padding(20)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(ExtensionSection.allCases) { item in
                        Button { section = item } label: { Label(item.rawValue, systemImage: item.icon).font(.system(size: 12)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(10).background(section == item ? Palette.selected : .clear, in: RoundedRectangle(cornerRadius: 7)) }.buttonStyle(.plain)
                    }
                    Spacer()
                }.padding(10).frame(width: 175)
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(section.rawValue).font(.headline).lineLimit(1)
                        Spacer(minLength: 8)
                        Picker("Scope", selection: $scope) { ForEach(ConfigurationScope.allCases) { Text($0.title).tag($0) } }.labelsHidden().fixedSize().accessibilityLabel("Configuration scope")
                    }.padding(16)
                    if let model {
                        content(model)
                        if model.operating { HStack { ProgressView().controlSize(.small); Text("Working…").font(.caption); Spacer(); Button("Stop") { model.cancel() } }.padding(12) }
                    } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                    if let failure { Text(failure).font(.caption).foregroundStyle(.orange).padding(16).textSelection(.enabled) }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Text("Edits apply to the selected scope. Secrets stay outside chat history.").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 8)
                if let chat = store.selected, chat.workspaceDirectory == project {
                    Button(reloading ? "Reconnecting…" : "Reconnect agent") {
                        reloading = true
                        Task { defer { reloading = false }; do { try await store.reloadAgentConfiguration(chat); failure = nil } catch { failure = error.localizedDescription } }
                    }.disabled(chat.busy || chat.hasLiveAgentWork || !chat.pendingPrompts.isEmpty || !chat.pendingSettings.isEmpty || reloading || model?.operating == true)
                }
            }.padding(16)
        }.frame(width: 820, height: 620)
        .task {
            do {
                guard store.settings.configurationRuntime != nil else { throw ACPError.workspace("Configuration management requires the verified Claude ACP adapter. ACP session options remain available for other agents.") }
                let directory = AgentSettings.environment["CLAUDE_CONFIG_DIR"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
                model = ExtensionsModel(configuration: try AgentConfiguration(project: project, configurationDirectory: directory))
                try await load()
            } catch { failure = error.localizedDescription }
        }
        .task(id: scope.rawValue + section.rawValue) { if model != nil { do { try await load() } catch { if !(error is CancellationError) { failure = error.localizedDescription } } } }
        .onDisappear { model?.cancel() }
        .onChange(of: store.selectedID) { _, _ in model?.cancel(); model?.liveServers = [] }
        .onChange(of: liveChat?.connectionGeneration) { _, _ in model?.cancel(); model?.liveServers = [] }
        .onChange(of: scope) { _, _ in if section == .plugins { model?.cancel() } }
        .onChange(of: section) { _, _ in model?.dismissPluginReview() }
        .onChange(of: pluginName) { _, _ in model?.cancel() }
        .onChange(of: store.settings.executable) { _, _ in model?.cancel() }
        .onChange(of: store.settings.arguments) { _, _ in model?.cancel() }
    }
    @ViewBuilder private func content(_ model: ExtensionsModel) -> some View {
        switch section {
        case .settings, .instructions, .hooks:
            if section == .hooks { Text("Edit the hooks key in this scope's settings. Other settings are preserved. Hook commands run through Claude when their event occurs.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16) }
            ConfigurationEditor(model: model)
        case .skills:
            if let chat = liveChat { Button("Reload skills in this agent") { model.invokeLive(store: store, chat: chat, operation: .reloadSkills) }.disabled(model.operating || !store.canChangeLiveConfiguration(chat)).padding(.horizontal, 16) }
            if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16) }
            if let failure = model.failure { Text(failure).font(.caption).foregroundStyle(.orange).padding(.horizontal, 16) }
            List(records) { item in
                VStack(alignment: .leading, spacing: 5) { HStack { Text(item.name).fontWeight(.medium); Spacer(); Text(item.scope.title).foregroundStyle(.secondary).font(.caption) }; Text(item.description).font(.caption).foregroundStyle(.secondary); Text(item.path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle); Button("Open source") { NSWorkspace.shared.open(URL(fileURLWithPath: item.path)) }.font(.caption) }.padding(.vertical, 6)
            }
            Text("Files are browsed without executing their content. Reconnect after edits to refresh the agent's command list.").font(.caption).foregroundStyle(.secondary).padding(16)
        case .effective:
            Button("Refresh from Claude SDK") { Task { do { try await resolve(model); failure = nil } catch { failure = error.localizedDescription } } }.padding(.horizontal, 16)
            if !effective.isEmpty { ScrollView { ToolLog(text: effective, command: false).frame(maxWidth: .infinity, alignment: .leading).padding(16) } }
        case .mcp:
            ScrollView { VStack(alignment: .leading, spacing: 10) {
                Text("Claude manages user/local servers in its global configuration and shared project servers in .mcp.json. Desktop servers are not imported automatically.").font(.caption).foregroundStyle(.secondary)
                TextField("Server name", text: $serverName).textFieldStyle(.roundedBorder)
                TextEditor(text: $serverJSON).font(.system(size: 12, design: .monospaced)).frame(height: 150).accessibilityLabel("MCP server JSON")
                HStack {
                    Button("Add server") { do { let json = try JSONDecoder().decode(JSONValue.self, from: Data(serverJSON.utf8)); invoke(model, .addMCP(name: serverName, configuration: json, scope: scope)) } catch { failure = "Enter valid server JSON." } }.disabled(scope == .managed || serverName.isEmpty)
                    Button("Remove server") { invoke(model, .removeMCP(name: serverName, scope: scope)) }.disabled(scope == .managed || serverName.isEmpty)
                    Button("Check status") { invoke(model, .checkMCP(name: serverName.isEmpty ? nil : serverName)) }
                }
                if let chat = liveChat {
                    LiveMCPConnectionsView(servers: model.liveServers, changing: model.operating, canChange: store.canChangeLiveConfiguration(chat), refresh: { model.invokeLive(store: store, chat: chat, operation: .status) }, change: { model.invokeLive(store: store, chat: chat, operation: $0) }, canAuthenticate: store.liveConfigurationCapability(chat)?.supportsAuthentication == true, authentication: model.authentication, signIn: { model.authenticate(store: store, chat: chat, name: $0) }, cancelSignIn: { model.cancel() })
                } else { Text("Connect this project's agent to view and control its live MCP servers.").font(.caption).foregroundStyle(.secondary) }
                if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                operationResult(model)
            }.padding(16) }
        case .plugins:
            VStack(alignment: .leading, spacing: 10) {
                TextField("Plugin name@marketplace", text: $pluginName).textFieldStyle(.roundedBorder)
                HStack { Button("Install") { invoke(model, .installPlugin(name: pluginName, scope: scope)) }; Button("Enable") { invoke(model, .enablePlugin(name: pluginName, scope: scope, enabled: true)) }; Button("Disable") { invoke(model, .enablePlugin(name: pluginName, scope: scope, enabled: false)) }; Button("Uninstall") { invoke(model, .uninstallPlugin(name: pluginName, scope: scope)) } }.disabled(pluginName.isEmpty || scope == .managed)
                HStack { TextField("Marketplace repository, path or URL", text: $marketplace).textFieldStyle(.roundedBorder); Button("Add") { invoke(model, .addMarketplace(source: marketplace)) }.disabled(marketplace.isEmpty || scope == .managed) }
                Button("Refresh installed plugins") { invoke(model, .plugins) }
                if let chat = liveChat { Button("Reload plugins in this agent") { model.invokeLive(store: store, chat: chat, operation: .reloadPlugins) }.disabled(!store.canChangeLiveConfiguration(chat)) }
                if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                if let review = model.pluginReview {
                    PluginInstallReviewView(review: review, changing: model.operating, accept: { model.acceptPluginReview(agent: store.settings) }, cancel: { model.dismissPluginReview() })
                }
                Text("Reload plugins in this agent or reconnect after installation. Command-based installs display the exact command for review.").font(.caption).foregroundStyle(.secondary)
                operationResult(model)
            }.padding(16).disabled(model.operating)
        }
    }
    @ViewBuilder private func operationResult(_ model: ExtensionsModel) -> some View {
        if !model.cliOutput.isEmpty { ScrollView { ToolLog(text: model.cliOutput, command: false).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 160) }
        if let failure = model.failure { Text(failure).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
    }
    private var liveChat: ChatSession? { guard let chat = store.selected, chat.workspaceDirectory == project, store.liveConfigurationCapability(chat) != nil else { return nil }; return chat }
    private func invoke(_ model: ExtensionsModel, _ operation: ConfigurationOperation) { model.invoke(agent: store.settings, operation: operation) }
    private func load() async throws {
        guard let model else { return }
        failure = nil
        switch section {
        case .settings, .hooks: try await model.select(scope: scope, kind: .settings)
        case .instructions: try await model.select(scope: scope, kind: .instructions)
        case .skills: records = try await model.configuration.extensions()
        case .effective: try await resolve(model)
        case .mcp, .plugins: break
        }
    }
    private func resolve(_ model: ExtensionsModel) async throws {
        guard let runtime = store.settings.configurationRuntime else { throw ACPError.workspace("The selected agent does not expose the verified Claude SDK resolver.") }
        let result = try await model.configuration.resolve(node: runtime.node, adapterEntry: runtime.entry, helper: runtime.helper)
        try Task.checkCancellation(); effective = result.pretty
    }
}

struct LiveMCPConnectionsView: View {
    let servers: [MCPServerConnection]
    let changing: Bool
    let canChange: Bool
    let refresh: () -> Void
    let change: (LiveConfigurationOperation) -> Void
    var canAuthenticate = false
    var authentication: MCPAuthentication?
    var signIn: (String) -> Void = { _ in }
    var cancelSignIn: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Live connections").font(.headline); Spacer(); Button("Refresh") { refresh() }.disabled(changing) }
            if servers.isEmpty { Text("Refresh to read this agent's actual server connections.").font(.caption).foregroundStyle(.secondary) }
            ForEach(servers) { server in
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text(server.name).fontWeight(.medium).lineLimit(1); Spacer(); Text(label(server.status)).font(.caption).foregroundStyle(server.status == .connected ? Color.green : .secondary).fixedSize() }
                    HStack { Text([server.source, server.scope].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary); Spacer(); Text("\(server.tools.count) tools").font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Button(server.status == .disabled ? "Enable" : "Disable") { change(.toggle(name: server.name, enabled: server.status == .disabled)) }
                        Button("Reconnect") { change(.reconnect(name: server.name)) }
                    }.font(.caption).disabled(changing || !canChange)
                    if let flow = authentication, flow.name == server.name {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Waiting for sign-in…").font(.caption).foregroundStyle(.secondary)
                            if let url = flow.url {
                                Text(url.host ?? "Authorization provider").font(.caption).lineLimit(1).truncationMode(.middle)
                                Button("Open in browser") { NSWorkspace.shared.open(url) }.font(.caption)
                            }
                            Button("Cancel sign-in") { cancelSignIn() }.font(.caption)
                        }
                    } else if server.status == .needsAuthentication {
                        if canAuthenticate { Button("Sign in") { signIn(server.name) }.font(.caption).disabled(changing || !canChange) }
                        else { Text("Reconnect with an adapter that supports MCP sign-in.").font(.caption).foregroundStyle(.secondary) }
                    }
                }.padding(10).background(Palette.muted, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
    private func label(_ status: MCPServerConnection.Status) -> String {
        switch status { case .connected: "Connected"; case .failed: "Failed"; case .needsAuthentication: "Authentication required"; case .pending: "Connecting"; case .disabled: "Disabled" }
    }
}

struct PluginInstallReviewView: View {
    let review: PluginInstallReview
    let changing: Bool
    let accept: () -> Void
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Review install command").font(.headline)
            HStack(spacing: 8) {
                Text(review.plugin).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Text(review.scope.title).font(.caption).foregroundStyle(.secondary).fixedSize()
            }
            Text("Installing this plugin will run the command below on this Mac.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView { ToolLog(text: review.command, command: true).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 80)
            if let url = review.archiveURL { Text(url).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled) }
            if review.kind == "command_source" { Text("Claude may run this command again when loading the plugin.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Cancel") { cancel() }
                Spacer(minLength: 8)
                Button("Run command and install") { accept() }.buttonStyle(.borderedProminent)
            }.disabled(changing)
        }.padding(12).background(Palette.muted, in: RoundedRectangle(cornerRadius: 10))
    }
}
