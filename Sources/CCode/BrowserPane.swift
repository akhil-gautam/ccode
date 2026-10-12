import SwiftUI
import AppKit
import WebKit
import CCodeCore

struct BrowserPane: View {
    @Bindable var chat: ChatSession
    let store: AppStore
    @State private var address = "http://127.0.0.1:3000/"
    @State private var failure: String?
    @State private var inspecting = false
    @State private var inspection = ""
    @State private var showInspector = false
    @State private var showLogin = false
    @State private var loginAddress = ""
    @State private var rememberLogin = false
    @State private var configuringServer = false
    @State private var showServerLogs = false
    @State private var serverLogs = ""
    @State private var serverExecutable = ""
    @State private var serverArguments = "[]"
    @State private var serverDirectory = ""
    @State private var serverURL = "http://127.0.0.1:3000/"
    private var browser: BrowserWorkspace { chat.browserWorkspace }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let tab = browser.selected {
                    Button { tab.agentNavigation = false; tab.webView.goBack() } label: { Image(systemName: "arrow.left") }.disabled(!tab.webView.canGoBack).help("Back")
                }
                TextField("URL", text: $address).textFieldStyle(.roundedBorder).onSubmit { navigate() }
                Button { if let tab = browser.selected { tab.agentNavigation = false; tab.webView.reload() } else { navigate() } } label: { Image(systemName: "arrow.clockwise") }.help("Reload")
                Button("Open") { navigate() }
                Menu {
                    Button("New tab") { navigate(newTab: true) }
                    Button("Login…") { loginAddress = address; showLogin = true }
                    Button("Developer inspection") { showInspector.toggle() }
                    Button("Configure dev server…") { configureServer() }.disabled(!chat.workspace.environment.isLocal)
                    Button("Dev server logs") { showServerLogs.toggle() }
                } label: { Image(systemName: "ellipsis") }
            }.buttonStyle(.plain).padding(12)
            if !browser.tabs.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(browser.tabs, id: \.id) { tab in
                            HStack(spacing: 8) {
                                Button { browser.selectedID = tab.id } label: { HStack(spacing: 5) { Image(systemName: tab.manualLogin ? "lock" : "globe"); Text(tab.title).lineLimit(1).frame(maxWidth: 160) } }
                                Button { browser.closeTab(tab.id) } label: { Image(systemName: "xmark").font(.system(size: 9)) }.help("Close tab")
                            }.buttonStyle(.plain).font(.caption).padding(8).background(browser.selectedID == tab.id ? Palette.selected : Palette.muted, in: RoundedRectangle(cornerRadius: 7))
                        }
                    }.padding(.horizontal, 12)
                }.frame(height: 38)
            }
            HStack(spacing: 10) {
                Button(chat.transcript.browserToolsEnabled == true ? "Disconnect agent tools" : "Connect agent tools") {
                    Task { do { try await store.setBrowserTools(chat, enabled: chat.transcript.browserToolsEnabled != true); failure = nil } catch { failure = error.localizedDescription } }
                }.disabled(!chat.workspace.environment.isLocal || chat.busy || chat.hasLiveAgentWork || !chat.pendingPrompts.isEmpty || !chat.pendingSettings.isEmpty)
                if let tab = browser.selected {
                    if tab.manualLogin {
                        Menu("Manual login") {
                            Button("Use signed-in profile for agent preview") {
                                Task { do { let preview = try await browser.previewFromLogin(tab.id); try browser.navigate(preview, to: preview.url); failure = nil } catch { failure = error.localizedDescription } }
                            }
                        }.help("After login, explicitly share this browser profile with a preview tab. Login tabs remain manual.")
                    }
                    else {
                        Button(browser.isAllowed(tab.url) ? "Revoke site access" : "Allow agent on this site") {
                            if browser.isAllowed(tab.url) { browser.revokeAgent(on: tab.id) } else { browser.allowAgent(on: tab.id) }
                        }.help("Grant applies only to this session and this URL's origin")
                        Button(tab.selectingElement ? "Cancel picking" : "Pick element") {
                            Task {
                                do {
                                    if tab.selectingElement { await browser.cancelElementPicking(tab.id) }
                                    else { try await browser.beginElementPicking(tab.id) }
                                    failure = nil
                                } catch { failure = error.localizedDescription }
                            }
                        }.disabled(tab.loading).help("Click an element in the preview to attach its context. Escape cancels.")
                    }
                }
                Spacer(minLength: 0)
                if browser.endpoint != nil { Image(systemName: "checkmark.circle").foregroundStyle(.green).help("Browser tool server connected") }
            }.font(.caption).padding(.horizontal, 12).padding(.vertical, 8)
            if chat.transcript.previewLaunch != nil {
                HStack {
                    Text(chat.previewStarting ? "Starting dev server…" : chat.previewActive ? "Dev server running" : "Dev server stopped").foregroundStyle(.secondary)
                    Spacer()
                    if chat.previewActive { Button("Stop") { Task { await store.stopPreview(chat) } } }
                    else { Button("Start") { if let configuration = chat.transcript.previewLaunch { startServer(configuration) } }.disabled(chat.closing || !chat.workspace.environment.isLocal) }
                    Button { configureServer() } label: { Image(systemName: "gearshape") }.help("Dev server configuration")
                }.font(.caption).padding(.horizontal, 12).padding(.bottom, 8)
            }
            Divider()
            if let tab = browser.selected {
                if tab.selectingElement { Text("Click an element to select it · Escape to cancel").font(.caption).foregroundStyle(.secondary).padding(8) }
                OwnedWebPreview(tab: tab).frame(maxWidth: .infinity, maxHeight: .infinity)
                if tab.loading { ProgressView().controlSize(.small).padding(5) }
                if let error = tab.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled).padding(10) }
                if let context = tab.selectedContext {
                    HStack { Label("Element selected", systemImage: "viewfinder"); Spacer(); Button("Add to message") { chat.draft += (chat.draft.isEmpty ? "" : "\n\n") + context; Task { await store.save(chat) } } }.font(.caption).padding(10)
                }
            } else {
                VStack(spacing: 12) { Image(systemName: "globe").font(.largeTitle); Text("Preview your running app"); Text("Open a local URL or documentation page. Allow a site to give the agent access.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if showInspector, let tab = browser.selected {
                Divider()
                HStack {
                    Text("Developer inspection").font(.caption.weight(.medium)); Spacer()
                    Button("DOM") { inspect(tab, tool: "browser_inspect") }
                    Button("Console / network") { inspect(tab, tool: "browser_diagnostics") }
                    Button { showInspector = false } label: { Image(systemName: "xmark") }
                }.font(.caption).buttonStyle(.plain).padding(10).disabled(inspecting)
                ScrollView { ToolLog(text: inspection.isEmpty ? "Allow this site, then inspect its DOM or recorded console/network events." : inspection, command: false).frame(maxWidth: .infinity, alignment: .leading).padding(10) }.frame(height: 160)
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.orange).textSelection(.enabled).padding(10) }
            if showServerLogs {
                Divider()
                ScrollView { ToolLog(text: serverLogs, command: false).frame(maxWidth: .infinity, alignment: .leading).padding(10) }.frame(height: 140)
            }
        }
        .task {
            while !Task.isCancelled {
                if showServerLogs, let snapshot = try? await chat.previewServer.snapshot() { serverLogs = snapshot.logs }
                do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
            }
        }
        .onChange(of: browser.selectedID) { _, _ in if let tab = browser.selected { address = tab.url.absoluteString }; inspection = "" }
        .onChange(of: browser.selected?.url) { _, url in if let url { address = url.absoluteString } }
        .sheet(isPresented: $showLogin) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Manual login").font(.headline)
                Text("The agent cannot inspect or interact with this tab. Its browser profile is separate from preview tabs.").font(.caption).foregroundStyle(.secondary)
                TextField("Login URL", text: $loginAddress).textFieldStyle(.roundedBorder)
                Toggle("Remember this login on this Mac", isOn: $rememberLogin)
                HStack { Spacer(); Button("Cancel") { showLogin = false }; Button("Open login") {
                    do { guard let url = URL(string: loginAddress) else { throw ACPError.workspace("Enter an HTTP(S) URL.") }; let tab = try browser.open(url, login: true, persistentLogin: rememberLogin); try browser.navigate(tab, to: url); showLogin = false } catch { failure = error.localizedDescription; showLogin = false }
                }.buttonStyle(.borderedProminent) }
            }.padding(24).frame(width: 430)
        }
        .sheet(isPresented: $configuringServer) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Dev server").font(.headline)
                Text("Runs in this session's project. Closing the pane or reconnecting the agent keeps it running; closing the session stops it.").font(.caption).foregroundStyle(.secondary)
                TextField("Executable", text: $serverExecutable).textFieldStyle(.roundedBorder)
                TextField("Arguments as a JSON array", text: $serverArguments).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                TextField("Project directory", text: $serverDirectory).textFieldStyle(.roundedBorder)
                TextField("Preview URL (http://127.0.0.1:port/)", text: $serverURL).textFieldStyle(.roundedBorder)
                HStack { Spacer(); Button("Cancel") { configuringServer = false }; Button("Save") { saveServer(start: false) }; Button("Start") { saveServer(start: true) }.buttonStyle(.borderedProminent) }.disabled(chat.previewActive)
                if let failure { Text(failure).font(.caption).foregroundStyle(.orange) }
            }.padding(24).frame(width: 480)
        }
    }
    private func navigate(newTab: Bool = false) {
        do {
            guard let url = URL(string: address) else { throw ACPError.workspace("Enter an HTTP(S) URL.") }
            let tab: BrowserTab
            if newTab || browser.selected == nil || BrowserWorkspace.isAuthentication(url) { tab = try browser.open(url) }
            else { tab = browser.selected! }
            try browser.navigate(tab, to: url); failure = nil
        } catch { failure = error.localizedDescription }
    }
    private func inspect(_ tab: BrowserTab, tool: String) {
        inspecting = true
        Task {
            defer { inspecting = false }
            do { let result = try await browser.callTool(tool, arguments: ["tabId": .string(tab.id.uuidString)]); inspection = result["content"].array.first?["text"].string ?? ""; failure = nil }
            catch { failure = error.localizedDescription }
        }
    }
    private func configureServer() {
        let saved = chat.transcript.previewLaunch
        serverExecutable = saved?.executable ?? AgentSettings.locate("npm") ?? ""
        serverArguments = (saved?.arguments).map { String(decoding: (try? JSONEncoder().encode($0)) ?? Data(), as: UTF8.self) } ?? "[\"run\",\"dev\"]"
        serverDirectory = saved?.directory ?? chat.workspaceDirectory; serverURL = saved?.url ?? address
        failure = nil; configuringServer = true
    }
    private func saveServer(start: Bool) {
        do {
            let arguments = try JSONDecoder().decode([String].self, from: Data(serverArguments.utf8))
            let configuration = PreviewLaunchConfiguration(executable: serverExecutable, arguments: arguments, directory: serverDirectory, url: serverURL)
            guard !serverExecutable.isEmpty, let url = URL(string: serverURL), url.scheme == "http", url.host == "127.0.0.1", url.port != nil else { throw ACPError.workspace("Enter an executable and a loopback HTTP URL with an explicit port.") }
            chat.transcript.previewLaunch = configuration; configuringServer = false
            if start { startServer(configuration) } else { Task { await store.save(chat) } }
        } catch { failure = error.localizedDescription }
    }
    private func startServer(_ configuration: PreviewLaunchConfiguration) {
        Task { do { try await store.startPreview(chat, configuration: configuration); failure = nil } catch { failure = error.localizedDescription; showServerLogs = true } }
    }
}

private struct OwnedWebPreview: NSViewRepresentable {
    let tab: BrowserTab
    func makeNSView(context: Context) -> WKWebView { tab.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
    // The session owns navigation and teardown, including while this pane is hidden.
    static func dismantleNSView(_ view: WKWebView, coordinator: ()) {}
}
