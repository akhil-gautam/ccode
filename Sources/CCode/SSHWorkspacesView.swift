import SwiftUI
import CCodeCore

struct SSHWorkspacesView: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var name = ""
    @State private var host = ""
    @State private var port = ""
    @State private var key = ""
    @State private var project = ""
    @State private var executable = "claude-agent-acp"
    @State private var arguments = "[]"
    @State private var failure: String?
    @State private var status: String?
    @State private var working = false
    @State private var operation: Task<Void, Never>?
    @State private var checkingPeer: ACPConnection?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SSH workspaces").font(.title2.weight(.medium))
                Spacer()
                Button { close() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Close SSH workspaces")
            }.padding(22)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    List(selection: $selectedID) {
                        ForEach(store.settings.sshConnections ?? []) { preset in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(preset.host.name).lineLimit(1)
                                Text(preset.host.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }.tag(preset.id)
                        }
                    }.listStyle(.sidebar)
                    Button("Add SSH connection…") { selectedID = nil; reset() }.disabled(working).padding(.horizontal, 12)
                }.padding(.vertical, 12).frame(width: 210)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Run your agent on a remote Linux or Mac workspace.").foregroundStyle(.secondary)
                        field("Name", "Build VM", text: $name)
                        field("SSH host", "user@hostname or config alias", text: $host)
                        HStack(alignment: .top, spacing: 12) {
                            field("Port (optional)", "SSH config", text: $port).frame(width: 120)
                            field("SSH key (optional)", "/Users/you/.ssh/id_ed25519", text: $key)
                        }
                        field("Remote project folder", "/home/you/project", text: $project)
                        field("Remote ACP executable", "claude-agent-acp", text: $executable)
                        field("Arguments (JSON array)", "[]", text: $arguments)
                        Text("Uses your OpenSSH config, keys and SSH agent. Unknown or changed host keys are refused. Install the ACP adapter and Python 3 on the host; sign in there using its terminal.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Check connection") { run(connect: false) }.disabled(working)
                            if working { ProgressView().controlSize(.small) }
                            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                        }
                        if let failure { Text(failure).font(.caption).foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                    }.padding(22).disabled(working)
                }
            }
            Divider()
            HStack {
                if selectedID != nil { Button("Remove saved connection") { remove() }.disabled(working) }
                Spacer()
                Button(working ? "Stop" : "Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button("Save connection") { save() }.disabled(working)
                Button("Start SSH session") { run(connect: true) }.buttonStyle(.borderedProminent).disabled(working).keyboardShortcut(.defaultAction)
            }.padding(18)
        }.frame(width: 760, height: 640).background(Palette.sidebar)
        .onAppear { selectedID = store.selectedSSHPresetID; load() }
        .onChange(of: selectedID) { _, _ in if !working { load() } }
        .onDisappear { operation?.cancel(); let peer = checkingPeer; Task { await peer?.close() } }
    }
    private func field(_ title: String, _ placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption).foregroundStyle(.secondary); TextField(placeholder, text: text).textFieldStyle(.roundedBorder).accessibilityLabel(title) }
    }
    private func parsed() throws -> SSHConnectionPreset {
        let portNumber: Int?
        if port.trimmingCharacters(in: .whitespaces).isEmpty { portNumber = nil }
        else { guard let number = Int(port) else { throw ACPError.workspace("Enter a numeric SSH port.") }; portNumber = number }
        let configuration = try SSHConfiguration(id: selectedID ?? UUID(), name: name, host: host.trimmingCharacters(in: .whitespaces), port: portNumber, identityFile: key.isEmpty ? nil : key)
        return try SSHConnectionPreset(host: configuration, projectPath: project, executable: executable, arguments: JSONDecoder().decode([String].self, from: Data(arguments.utf8)))
    }
    private func persist(_ preset: SSHConnectionPreset) throws {
        var presets = store.settings.sshConnections ?? []
        if let index = presets.firstIndex(where: { $0.id == preset.id }) { presets[index] = preset }
        else { guard presets.count < 64 else { throw ACPError.workspace("At most 64 SSH connections can be saved.") }; presets.append(preset) }
        store.settings.sshConnections = presets; store.settings.save(); selectedID = preset.id
    }
    private func save() { do { try persist(parsed()); failure = nil; status = "Connection saved" } catch { failure = error.localizedDescription } }
    private func remove() { store.settings.sshConnections?.removeAll { $0.id == selectedID }; store.settings.save(); selectedID = nil; reset() }
    private func reset() { name = ""; host = ""; port = ""; key = ""; project = ""; executable = "claude-agent-acp"; arguments = "[]"; failure = nil; status = nil }
    private func load() {
        guard let preset = store.settings.sshConnections?.first(where: { $0.id == selectedID }) else { reset(); return }
        name = preset.host.name; host = preset.host.host; port = preset.host.port.map(String.init) ?? ""; key = preset.host.identityFile ?? ""
        project = preset.projectPath; executable = preset.executable; arguments = (try? String(data: JSONEncoder().encode(preset.arguments), encoding: .utf8)) ?? "[]"
        failure = nil; status = nil
    }
    private func close() {
        if working { operation?.cancel(); let peer = checkingPeer; Task { await peer?.close() }; return }
        store.showSSHWorkspaces = false; dismiss()
    }
    private func run(connect: Bool) {
        do {
            let preset = try parsed(); working = true; failure = nil; status = nil
            operation = Task { @MainActor in
                defer { working = false; operation = nil; checkingPeer = nil }
                do {
                    if connect {
                        let id = try await store.createSSHWorkspace(host: preset.host, path: preset.projectPath, executable: preset.executable, arguments: preset.arguments)
                        try persist(preset)
                        guard let chat = store.chat(id) else { throw ACPError.workspace("SSH session could not be opened.") }
                        try await store.connect(chat)
                        store.showSSHWorkspaces = false; dismiss()
                    } else {
                        let transport = try SSHTransport(configuration: preset.host, executable: store.sshExecutable)
                        let frozen = try await transport.resolvedConfiguration()
                        let remote = try RemoteWorkspace(root: preset.projectPath, transport: SSHTransport(configuration: frozen, executable: store.sshExecutable))
                        _ = try await remote.resolve(preset.projectPath, directory: true)
                        let peer = ACPConnection(onUpdates: { _ in }, onRequest: { method, _ in throw ACPError.methodNotFound(method) })
                        checkingPeer = peer
                        do {
                            try await peer.start(environment: .ssh(frozen), executable: preset.executable, arguments: preset.arguments, directory: preset.projectPath, sshExecutable: store.sshExecutable)
                            let result = try await peer.request("initialize", params: ["protocolVersion": 1, "clientCapabilities": ExecutionEnvironment.ssh(frozen).clientCapabilities, "clientInfo": ["name": "ccode", "version": "0.1.0"]], timeout: .seconds(20))
                            guard result["protocolVersion"].int == 1 else { throw ACPError.protocolViolation("Remote agent must support ACP v1.") }
                            status = "Connected: " + result["agentInfo"]["name"].string
                            await peer.close()
                        } catch { await peer.close(); throw error }
                    }
                } catch { failure = error is CancellationError ? "Connection stopped" : error.localizedDescription }
            }
        } catch { failure = error.localizedDescription }
    }
}
