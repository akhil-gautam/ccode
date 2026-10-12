import SwiftUI
import AppKit
import CCodeCore

struct SettingsView: View {
    @Bindable var store: AppStore
    @State private var executable = ""
    @State private var arguments = "[]"
    @State private var appearance = "system"
    @State private var worktree = false
    @State private var error: String?
    @State private var verifying = false
    @State private var result: String?
    @State private var showExtensions = false
    @State private var showSSH = false
    @State private var showNativePermissions = false
    private var customizationProject: String { store.selected.map { $0.workspace.environment.isLocal ? $0.workspaceDirectory : "" } ?? store.newSessionDraft.projectPath }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Customize ccode").font(.title2.weight(.medium)); Spacer(); Button { store.showSettings = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
            Text("Agent connection").font(.headline)
            Text("Run any ACP v1 agent over stdio. Claude Code uses the Claude ACP adapter.").foregroundStyle(.secondary)
            HStack { TextField("Absolute executable path", text: $executable).textFieldStyle(.roundedBorder); Button("Choose…") { let panel = NSOpenPanel(); panel.canChooseDirectories = false; if panel.runModal() == .OK { executable = panel.url?.path ?? "" } } }
            Text("Arguments (JSON array)").font(.caption).foregroundStyle(.secondary)
            TextField("[]", text: $arguments).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
            HStack { Button(verifying ? "Checking…" : "Check connection") { check() }.disabled(verifying); if verifying { ProgressView().controlSize(.small) }; if let result { Text(result).font(.caption).foregroundStyle(.green) } }
            Divider()
            Button("Manage Claude settings and extensions…") { showExtensions = true }.disabled(customizationProject.isEmpty || store.settings.configurationRuntime == nil)
            Text("Instructions, scopes, permissions, hooks, MCP servers, skills and plugins for the selected project.").font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack { Button("Manage SSH workspaces…") { showSSH = true }; Button("Computer & simulator access…") { showNativePermissions = true } }
            Text("Claude adapter setup").font(.headline)
            Text("npm install -g @agentclientprotocol/claude-agent-acp@0.84.0").font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            Text("Requires Node 22 or later. Sign in using your own terminal, then reconnect.").font(.caption).foregroundStyle(.secondary)
            HStack { Text("claude-agent-acp --cli auth login").font(.system(size: 12, design: .monospaced)).textSelection(.enabled); Spacer(); Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("claude-agent-acp --cli auth login", forType: .string) } }
            Link("ACP adapter documentation", destination: URL(string: "https://github.com/agentclientprotocol/claude-agent-acp")!).font(.caption)
            Divider()
            Picker("Appearance", selection: $appearance) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }.pickerStyle(.segmented)
            Toggle("Use isolated Git worktrees for new sessions", isOn: $worktree)
            HStack {
                Text("Session notifications")
                Spacer()
                if store.settings.sessionNotifications == true {
                    Button("Turn off") { store.settings.sessionNotifications = false; store.settings.save(); store.attentionNotifications?.stopDelivery(); store.notificationStatus = "Notifications turned off" }
                } else {
                    Button("Enable…") { Task { await store.enableSessionNotifications() } }
                }
            }
            if let status = store.notificationStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
            if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack { Text("Native UI · ACP v1").font(.caption).foregroundStyle(.tertiary); Spacer(); Button("Cancel") { store.showSettings = false }.keyboardShortcut(.cancelAction); Button("Save") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 620)
        .onAppear { executable = store.settings.executable; arguments = (try? String(data: JSONEncoder().encode(store.settings.arguments), encoding: .utf8)) ?? "[]"; appearance = store.settings.appearance; worktree = store.settings.defaultWorktree }
        .sheet(isPresented: $showSSH, onDismiss: { store.showSSHWorkspaces = false }) { SSHWorkspacesView(store: store) }
        .sheet(isPresented: $showNativePermissions) { NativePermissionsView() }
        .sheet(isPresented: $showExtensions) { ExtensionsView(store: store, project: customizationProject) }
    }
    private func parsed() throws -> [String] {
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else { throw ACPError.workspace("Choose an existing executable using its absolute path.") }
        return try JSONDecoder().decode([String].self, from: Data(arguments.utf8))
    }
    private func save() {
        do { let args = try parsed(); store.settings.executable = executable; store.settings.arguments = args; store.settings.appearance = appearance; store.settings.defaultWorktree = worktree; store.settings.save(); store.showSettings = false }
        catch { self.error = error.localizedDescription }
    }
    private func check() {
        do {
            let args = try parsed(), path = executable; verifying = true; error = nil; result = nil
            Task {
                let peer = ACPConnection(onUpdates: { _ in }, onRequest: { method, _ in throw ACPError.methodNotFound(method) })
                do {
                    try await peer.start(executable: path, arguments: args, directory: FileManager.default.homeDirectoryForCurrentUser.path, environment: AgentSettings.environment)
                    let handshake = try await peer.request("initialize", params: ["protocolVersion": 1, "clientCapabilities": [:], "clientInfo": ["name": "ccode", "version": "0.1.0"]], timeout: .seconds(15))
                    guard handshake["protocolVersion"].int == 1 else { throw ACPError.protocolViolation("Agent protocol is incompatible with ACP v1.") }
                    result = "Connected: \(handshake["agentInfo"]["name"].string)"
                } catch { self.error = error.localizedDescription }
                await peer.close(); verifying = false
            }
        } catch { self.error = error.localizedDescription }
    }
}
