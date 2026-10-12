import SwiftUI
import AppKit
import CCodeCore
@preconcurrency import SwiftTerm

final class NativeTerminalView: TerminalView {
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.makeFirstResponder(self) }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityLabel() -> String? { "Terminal" }
    override func isAccessibilityFocused() -> Bool { window?.firstResponder === self }
    override func setAccessibilityFocused(_ focused: Bool) { if focused { window?.makeFirstResponder(self) } }
    override func accessibilityValue() -> Any? {
        let terminal = getTerminal()
        return (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true, characterProvider: { terminal.getCharacter(for: $0) }) }.joined(separator: "\n")
    }
}

@MainActor @Observable final class TerminalTab: Identifiable, @preconcurrency TerminalViewDelegate {
    let id = UUID()
    let directory: String
    let environment: ExecutionEnvironment
    var title = "Terminal"
    var ready = false
    var ended = false
    var failure: String?
    @ObservationIgnored let view: TerminalView
    @ObservationIgnored private var process: PTYSession?
    @ObservationIgnored private var launch: Task<Void, Never>?
    @ObservationIgnored private var closing = false
    @ObservationIgnored private var startupInput = Data()

    init(directory: String, environment: ExecutionEnvironment = .local, sshExecutable: String = "/usr/bin/ssh", localEnvironment: [String: String]? = nil) {
        self.directory = directory; self.environment = environment
        view = NativeTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400), font: .monospacedSystemFont(ofSize: 12, weight: .regular), options: TerminalOptions(cursorStyle: .steadyBlock, scrollback: 1000, enableSixelReported: false, kittyImageCacheLimitBytes: 8 * 1024 * 1024))
        view.nativeBackgroundColor = NSColor(Palette.sidebar)
        view.nativeForegroundColor = .labelColor
        view.terminalDelegate = self
        let processEnvironment = localEnvironment ?? AgentSettings.environment
        launch = Task { [weak self] in
            do {
                let executable: String, arguments: [String], localDirectory: String
                if case .ssh(let host) = environment {
                    let transport = try SSHTransport(configuration: host, executable: sshExecutable)
                    try await transport.verifyIdentity()
                    _ = try await RemoteWorkspace(root: directory, transport: transport).resolve(directory, directory: true)
                    let launch = try transport.launch(executable: "/bin/sh", arguments: ["-l", "-i"], directory: directory)
                    executable = launch.executable; arguments = launch.arguments.map { $0 == "-T" ? "-tt" : $0 }; localDirectory = launch.directory
                } else { executable = "/bin/zsh"; arguments = ["-l", "-i"]; localDirectory = directory }
                let process = try await Task.detached { [weak self] in
                    try PTYSession(executable: executable, arguments: arguments, directory: localDirectory, environment: processEnvironment, onData: { [weak self] data in
                        await self?.receive(data)
                    }, onExit: { [weak self] status in
                        await self?.didExit(status)
                    })
                }.value
                guard let self, !self.closing, !Task.isCancelled else { await process.close(); return }
                self.process = process
                if !self.startupInput.isEmpty { try process.send(self.startupInput); self.startupInput.removeAll() }
                process.resize(columns: self.view.getTerminal().cols, rows: self.view.getTerminal().rows)
                self.ready = true
            } catch { self?.failure = error.localizedDescription; self?.ended = true }
        }
    }
    private func receive(_ data: Data) { view.feed(byteArray: Array(data)[...]) }
    private func didExit(_ status: Int32) { ended = true; view.feed(text: "\r\n[Process ended: \(status)]\r\n") }
    func close() async {
        closing = true; launch?.cancel(); await launch?.value
        await process?.close(); process = nil; ended = true
        view.terminalDelegate = nil
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { process?.resize(columns: newCols, rows: newRows) }
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard !closing, !ended else { return }
        do {
            if let process { try process.send(Data(data)) }
            else {
                // Shells can query the terminal before the async launch is published.
                guard startupInput.count + data.count <= 64 * 1024 else { closing = true; throw ACPError.protocolViolation("Terminal startup input exceeds its memory limit.") }
                startupInput.append(contentsOf: data)
            }
        } catch { failure = error.localizedDescription }
    }
    func setTerminalTitle(source: TerminalView, title: String) { self.title = String(title.prefix(256)) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), (environment.isLocal ? ["http", "https", "file"] : ["http", "https"]).contains(url.scheme ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
    // OSC 52 programmatic clipboard requests use SwiftTerm's deny/no-op defaults.
}

struct TerminalPane: View {
    @Bindable var chat: ChatSession
    let store: AppStore
    @State private var closing: Set<UUID> = []
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(chat.terminalTabs) { tab in
                            HStack(spacing: 8) {
                                Button { chat.activeTerminalID = tab.id } label: { Text(tab.title).lineLimit(1).frame(maxWidth: 150).help(tab.directory) }
                                Button { close(tab) } label: { Image(systemName: "xmark").font(.system(size: 9)) }.help("Close terminal and stop its processes").disabled(closing.contains(tab.id))
                            }.buttonStyle(.plain).font(.caption).padding(8).background(chat.activeTerminalID == tab.id ? Palette.selected : Palette.muted, in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }
                Button { add() } label: { Image(systemName: "plus") }.buttonStyle(.plain).help("New terminal").disabled(chat.closing || chat.terminalTabs.count >= 8)
            }.padding(10)
            Divider()
            if let tab = chat.terminalTabs.first(where: { $0.id == chat.activeTerminalID }) {
                if tab.ready { TerminalHost(tab: tab).id(tab.id) }
                else if !tab.ended { ProgressView("Starting terminal…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                if let failure = tab.failure { Text(failure).font(.caption).foregroundStyle(.orange).textSelection(.enabled).padding(10) }
                if tab.ended { HStack { Text("Process ended").foregroundStyle(.secondary); Spacer(); Button("New terminal") { add() }.disabled(chat.closing || chat.terminalTabs.count >= 8) }.font(.caption).padding(10) }
            } else { Text("Open a terminal to run commands in this project.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.onAppear { if chat.terminalTabs.isEmpty { add() } }
    }
    private func add() { do { _ = try store.openWorkspaceTerminal(chat) } catch { store.error = error.localizedDescription } }
    private func close(_ tab: TerminalTab) {
        guard closing.insert(tab.id).inserted else { return }
        Task {
            await tab.close(); chat.terminalTabs.removeAll { $0.id == tab.id }
            if chat.activeTerminalID == tab.id { chat.activeTerminalID = chat.terminalTabs.last?.id }
            closing.remove(tab.id)
        }
    }
}

private struct TerminalHost: NSViewRepresentable {
    let tab: TerminalTab
    func makeNSView(context: Context) -> TerminalView {
        tab.view
    }
    func updateNSView(_ view: TerminalView, context: Context) {}
    // Pane/session switches keep the same bounded terminal buffer and live PTY.
}
