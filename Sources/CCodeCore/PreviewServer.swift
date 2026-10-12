import Foundation

public struct PreviewLaunchConfiguration: Codable, Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    public let directory: String
    public let url: String
    public init(executable: String, arguments: [String], directory: String, url: String) {
        self.executable = executable; self.arguments = arguments; self.directory = directory; self.url = url
    }
}
public struct PreviewServerSnapshot: Sendable {
    public enum Phase: String, Sendable { case stopped, starting, ready, failed }
    public let phase: Phase
    public let url: String?
    public let logs: String
}
public actor PreviewServer {
    private let workspace: Workspace
    private let terminals = TerminalService()
    private var phase: PreviewServerSnapshot.Phase = .stopped
    private var url: String?
    private var logs = ""
    private var terminal: String?
    private var generation = UUID()
    private var stopping = false
    private var startup: Task<Void, any Error>?
    private var monitor: Task<Void, Never>?
    public var currentPhase: PreviewServerSnapshot.Phase { phase }
    public init(workspace: Workspace) { self.workspace = workspace }
    public func start(_ configuration: PreviewLaunchConfiguration, deadline: Duration = .seconds(30)) async throws {
        guard workspace.environment.isLocal else { throw ACPError.workspace("SSH preview forwarding is unavailable. Run the server in the remote terminal and use an explicitly configured tunnel.") }
        guard !stopping, startup == nil, terminal == nil else { throw ACPError.workspace("Stop the current preview server first.") }
        guard deadline > .zero, deadline <= .seconds(120) else { throw ACPError.workspace("Preview readiness deadline must be between 0 and 120 seconds.") }
        let epoch = UUID(); generation = epoch; phase = .starting; logs = ""; url = nil
        let task = Task { try await self.launch(configuration, deadline: deadline, epoch: epoch) }
        startup = task
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            if generation == epoch { startup = nil }
        } catch {
            if generation == epoch { startup = nil; phase = .failed }
            throw error
        }
    }
    public func snapshot() async throws -> PreviewServerSnapshot {
        if let terminal, let output = try? await terminals.output(terminal) { logs = output["output"].string }
        return .init(phase: phase, url: url, logs: logs)
    }
    public func stop() async {
        guard !stopping else { if let startup { _ = try? await startup.value }; return }
        stopping = true; generation = UUID()
        let pending = startup, watching = monitor
        pending?.cancel(); watching?.cancel()
        if let terminal, let output = try? await terminals.output(terminal) { logs = output["output"].string }
        await terminals.close()
        _ = try? await pending?.value; await watching?.value
        terminal = nil; startup = nil; monitor = nil; phase = .stopped; stopping = false
    }

    private func launch(_ configuration: PreviewLaunchConfiguration, deadline: Duration, epoch: UUID) async throws {
        let directory = try await workspace.scoped(configuration.directory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue,
              !configuration.executable.isEmpty,
              let endpoint = URL(string: configuration.url), endpoint.scheme == "http", endpoint.host == "127.0.0.1",
              endpoint.user == nil, endpoint.password == nil, let port = endpoint.port, (1...65535).contains(port)
        else { throw ACPError.workspace("Choose an existing project directory and a loopback HTTP URL with an explicit port.") }
        try check(epoch)
        guard try await listenerPIDs(port: port, directory: directory.path).isEmpty else { throw ACPError.workspace("Preview port \(port) is already in use.") }
        try check(epoch)
        let id = try await terminals.create(command: configuration.executable, arguments: configuration.arguments, directory: directory.path, byteLimit: 256 * 1024)
        do {
            try check(epoch); terminal = id; url = endpoint.absoluteString
            let clock = ContinuousClock(), expires = clock.now.advanced(by: deadline)
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.timeoutIntervalForRequest = 0.5; sessionConfiguration.timeoutIntervalForResource = 0.5
            let session = URLSession(configuration: sessionConfiguration, delegate: LocalReadinessDelegate(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            while clock.now < expires {
                try check(epoch)
                let output = try await terminals.output(id); logs = output["output"].string
                guard output["exitStatus"].isNull else { throw ACPError.workspace("Preview server exited before it was ready. Check its logs.") }
                let listeners = try await listenerPIDs(port: port, directory: directory.path)
                if !listeners.isEmpty {
                    for pid in listeners {
                        guard await terminals.ownsProcess(id, pid: pid) else { throw ACPError.workspace("Preview port was taken by another process.") }
                    }
                    var request = URLRequest(url: endpoint); request.httpMethod = "HEAD"
                    if let (_, response) = try? await session.data(for: request), response is HTTPURLResponse {
                        try check(epoch); phase = .ready
                        monitor = Task { [weak self] in
                            let result = try? await self?.terminals.wait(id)
                            guard !Task.isCancelled else { return }
                            await self?.exited(id, epoch: epoch, result: result)
                        }
                        return
                    }
                }
                try await Task.sleep(for: .milliseconds(75))
            }
            throw ACPError.workspace("Preview server did not answer before the readiness deadline. Check its logs.")
        } catch {
            if let output = try? await terminals.output(id), generation == epoch { logs = output["output"].string }
            try? await terminals.release(id)
            if terminal == id { terminal = nil }
            throw error
        }
    }
    private func check(_ epoch: UUID) throws {
        try Task.checkCancellation()
        guard generation == epoch, !stopping else { throw CancellationError() }
    }
    private func exited(_ id: String, epoch: UUID, result: JSONValue?) async {
        guard generation == epoch, terminal == id else { return }
        if let output = try? await terminals.output(id) { logs = output["output"].string }
        try? await terminals.release(id)
        if generation == epoch { terminal = nil; monitor = nil; phase = .failed }
    }
    private func listenerPIDs(port: Int, directory: String) async throws -> [Int32] {
        let id = try await terminals.create(command: "/usr/sbin/lsof", arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"], directory: directory, byteLimit: 8192)
        do {
            let result = try await terminals.wait(id), output = try await terminals.output(id)
            try await terminals.release(id)
            guard result["exitCode"].exactInteger == 0 || result["exitCode"].exactInteger == 1 else { throw ACPError.workspace("Cannot inspect preview port ownership.") }
            guard !output["truncated"].bool else { throw ACPError.workspace("Too many listeners on the preview port.") }
            return try output["output"].string.split(whereSeparator: \.isWhitespace).map {
                guard let pid = Int32($0), pid > 0 else { throw ACPError.workspace("Invalid preview listener identity.") }
                return pid
            }
        } catch { try? await terminals.release(id); throw error }
    }
}

private final class LocalReadinessDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Readiness must never follow a dev server redirect to an external/authentication site.
        completionHandler(nil)
    }
}
