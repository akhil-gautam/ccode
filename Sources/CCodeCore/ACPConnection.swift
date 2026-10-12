@preconcurrency import Foundation
import Darwin

public actor ACPConnection {
    public typealias Updates = @Sendable ([JSONValue]) async -> Void
    public typealias RequestHandler = @Sendable (String, JSONValue) async throws -> JSONValue
    private struct Pending {
        let continuation: CheckedContinuation<JSONValue, any Error>
        let deadline: Task<Void, Never>?
    }
    private var process: Process?
    private var input: FileHandle?
    private var writer: PipeWriter?
    private var processGroup: pid_t?
    private var nextID = 0
    private var pending: [Int: Pending] = [:]
    private var callbacks: [JSONValue: Task<Void, Never>] = [:]
    private var framer = LineFramer()
    private var updates: [JSONValue] = []
    private var flushTask: Task<Void, Never>?
    private var delivery: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var stderr = Data()
    private let onUpdates: Updates
    private let onRequest: RequestHandler
    private let onNotification: @Sendable (String, JSONValue) async -> Void
    private let onDisconnect: @Sendable (String) async -> Void
    private var didDisconnect = false

    public init(onUpdates: @escaping Updates, onRequest: @escaping RequestHandler, onNotification: @escaping @Sendable (String, JSONValue) async -> Void = { _, _ in }, onDisconnect: @escaping @Sendable (String) async -> Void = { _ in }) {
        self.onUpdates = onUpdates; self.onRequest = onRequest; self.onNotification = onNotification; self.onDisconnect = onDisconnect
    }

    public func hasPendingRequest(_ id: JSONValue) -> Bool { id.exactInteger.map { pending[$0] != nil } ?? false }

    public func start(executable: String, arguments: [String], directory: String, environment: [String: String]? = nil) throws {
        try Task.checkCancellation()
        guard !didDisconnect else { throw ACPError.disconnected("Connection is closed.") }
        guard process == nil else { throw ACPError.protocolViolation("Connection already started.") }
        let child = Process(), stdin = Pipe(), stdout = Pipe(), errors = Pipe()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        child.currentDirectoryURL = URL(fileURLWithPath: directory)
        child.environment = environment ?? ProcessInfo.processInfo.environment
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = errors
        let pipeWriter = try PipeWriter(stdin.fileHandleForWriting)
        try child.run()
        process = child; processGroup = ownedProcessGroup(child); input = stdin.fileHandleForWriting; writer = pipeWriter
        let out = stdout.fileHandleForReading, err = errors.fileHandleForReading
        // Blocking reads live on dedicated queues, never the UI or Swift cooperative executor.
        DispatchQueue(label: "ccode.acp.stdout.\(child.processIdentifier)").async { [weak self] in
            let bridge = DispatchSemaphore(value: 0)
            var remainingAfterExit: Int?
            do {
                while true {
                    let data = try readPipe(out, untilExit: child, remainingAfterExit: &remainingAfterExit)
                    if data.isEmpty { break }
                    Task { await self?.receive(data); bridge.signal() }
                    bridge.wait()
                }
                Task { await self?.eof() }
            } catch { Task { await self?.end("Agent output closed: \(error.localizedDescription)") } }
            try? out.close()
        }
        DispatchQueue(label: "ccode.acp.stderr.\(child.processIdentifier)").async { [weak self] in
            let bridge = DispatchSemaphore(value: 0)
            var remainingAfterExit: Int?
            while let data = try? readPipe(err, untilExit: child, remainingAfterExit: &remainingAfterExit), !data.isEmpty {
                Task { await self?.log(data); bridge.signal() }
                bridge.wait()
            }
            try? err.close()
        }
    }

    // Owned mutations may wait for the actual response/disconnect rather than
    // releasing their filesystem lock while a provider could still be writing.
    public func request(_ method: String, params: JSONValue, timeout: Duration? = .seconds(60)) async throws -> JSONValue {
        try Task.checkCancellation()
        guard input != nil, !didDisconnect else { throw ACPError.disconnected("Agent is not connected.") }
        nextID += 1
        let id = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let deadline: Task<Void, Never>? = timeout.map { duration in
                    Task { [weak self] in
                        do { try await Task.sleep(for: duration) } catch { return }
                        await self?.fail(id, error: ACPError.timeout(method))
                    }
                }
                pending[id] = Pending(continuation: continuation, deadline: deadline)
                do { try write(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]) }
                catch { fail(id, error: error) }
            }
        } onCancel: {
            Task { await self.fail(id, error: CancellationError()) }
        }
    }

    public func notify(_ method: String, params: JSONValue) throws {
        try write(["jsonrpc": "2.0", "method": .string(method), "params": params])
    }

    public func close() async {
        await end("Agent connection closed.", report: false)
        await cleanup?.value
    }

    public func diagnostics() -> String { String(decoding: stderr, as: UTF8.self) }

    private func write(_ message: JSONValue) throws {
        guard let writer, !didDisconnect else { throw ACPError.disconnected("Agent is not connected.") }
        var bytes = try JSONEncoder().encode(message)
        bytes.append(10)
        try writer.enqueue(bytes) { [weak self] result in
            if case .failure(let error) = result { Task { await self?.end("Agent input failed: \(error.localizedDescription)") } }
        }
    }

    private func receive(_ data: Data) async {
        guard !didDisconnect else { return }
        do {
            for line in try framer.append(data) {
                let message = try JSONDecoder().decode(JSONValue.self, from: line)
                guard case .object = message, message["jsonrpc"].string == "2.0" else { throw ACPError.protocolViolation("Invalid JSON-RPC envelope.") }
                if let method = message["method"].optionalString {
                    guard !method.isEmpty else { throw ACPError.protocolViolation("Empty RPC method.") }
                    if !message["id"].isNull {
                        let id = message["id"]
                        guard id.optionalString != nil || id.exactInteger != nil, callbacks.count < 128 else { throw ACPError.protocolViolation("Invalid agent request ID or too many pending requests.") }
                        guard callbacks[id] == nil else { throw ACPError.protocolViolation("Duplicate agent request ID.") }
                        let params = message["params"]
                        // Permission UI may wait indefinitely; keep reading other agent messages.
                        callbacks[id] = Task { [weak self, onRequest] in
                            do {
                                // A permission can refer to a tool/plan update immediately
                                // preceding it. Deliver those batched updates before opening UI.
                                await self?.flush()
                                try Task.checkCancellation()
                                let result = try await onRequest(method, params)
                                await self?.reply(id, result: result)
                            }
                            catch { await self?.replyError(id, error: error) }
                        }
                    } else if method == "session/update" {
                        updates.append(message["params"])
                        if updates.count >= 256 { await flush() }
                        if flushTask == nil {
                            flushTask = Task { [weak self] in
                                do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
                                await self?.flush()
                            }
                        }
                    } else if method == "$/cancel_request" {
                        callbacks[message["params"]["id"]]?.cancel()
                    } else {
                        await onNotification(method, message["params"])
                    }
                } else {
                    guard message["id"].exactInteger != nil,
                          (message.object["result"] != nil) != (message.object["error"] != nil) else { throw ACPError.protocolViolation("Invalid RPC response or response ID.") }
                    await resolve(message)
                }
            }
        } catch { await end("Invalid ACP output: \(error.localizedDescription)") }
    }

    private func resolve(_ message: JSONValue) async {
        await flush()
        guard let id = message["id"].exactInteger, let waiter = pending.removeValue(forKey: id) else { return }
        waiter.deadline?.cancel()
        if !message["error"].isNull {
            let value = message["error"]
            let error: ACPError = value["data"].isNull ? .remote(value["code"].int, value["message"].string) : .remoteFailure(value["code"].int, value["message"].string, value["data"])
            waiter.continuation.resume(throwing: error)
        }
        else { waiter.continuation.resume(returning: message["result"]) }
    }

    private func fail(_ id: Int, error: any Error) {
        guard let waiter = pending.removeValue(forKey: id) else { return }
        waiter.deadline?.cancel(); waiter.continuation.resume(throwing: error)
    }
    private func reply(_ id: JSONValue, result: JSONValue) {
        callbacks.removeValue(forKey: id)
        try? write(["jsonrpc": "2.0", "id": id, "result": result])
    }
    private func replyError(_ id: JSONValue, error: any Error) {
        callbacks.removeValue(forKey: id)
        let code: Int
        if let remoteCode = (error as? ACPError)?.rpcCode { code = remoteCode }
        else if case ACPError.methodNotFound = error { code = -32601 }
        else if error is CancellationError { code = -32800 }
        else { code = -32603 }
        try? write(["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(error.localizedDescription)]])
    }
    private func log(_ data: Data) { stderr.append(data); if stderr.count > 65536 { stderr = Data(stderr.suffix(65536)) } }
    private func flush() async {
        flushTask?.cancel(); flushTask = nil
        if !updates.isEmpty {
            let batch = updates, previous = delivery; updates.removeAll(keepingCapacity: true)
            delivery = Task { [onUpdates] in await previous?.value; await onUpdates(batch) }
        }
        await delivery?.value
    }
    private func eof() async {
        await end(framer.hasPartialFrame ? "Agent exited during an ACP frame." : "Agent exited. \(diagnostics().suffix(2000))")
    }
    private func end(_ reason: String, report: Bool = true) async {
        guard !didDisconnect else { return }
        didDisconnect = true
        if let child = process { cleanup = Task { await stopProcess(child, group: processGroup) } }
        await flush()
        for id in Array(pending.keys) { fail(id, error: ACPError.disconnected(reason)) }
        for task in callbacks.values { task.cancel() }
        callbacks.removeAll()
        writer?.close(); writer = nil
        try? input?.close(); input = nil
        await cleanup?.value
        if report { await onDisconnect(reason) }
    }
}

// FileHandle.read(upToCount:) may fill its requested count before returning.
// POSIX read returns the available pipe bytes, which an interactive peer requires.
func readPipe(_ handle: FileHandle, untilExit process: Process, remainingAfterExit: inout Int?) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: 65536)
    while true {
        if remainingAfterExit == nil, !process.isRunning {
            // Drain the bytes already buffered at parent exit. A descendant must
            // not keep the session alive by holding or continually writing stdout.
            var available: Int32 = 0
            // Darwin FIONREAD = _IOR('f',127,int); this C macro is not imported by Swift.
            guard ioctl(handle.fileDescriptor, 0x4004667f, &available) == 0 else { throw POSIXError(.EIO) }
            remainingAfterExit = Int(available)
        }
        if remainingAfterExit == 0 { return Data() }
        var state = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
        let ready = poll(&state, 1, 100)
        if ready == 0 { continue }
        if ready < 0 { if errno == EINTR { continue }; throw POSIXError(.EIO) }
        let count = Darwin.read(handle.fileDescriptor, &bytes, min(bytes.count, remainingAfterExit ?? bytes.count))
        if count >= 0 {
            if let remaining = remainingAfterExit { remainingAfterExit = remaining - count }
            return Data(bytes.prefix(count))
        }
        if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

extension JSONValue: Hashable {
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .object(let o): hasher.combine(0); for key in o.keys.sorted() { hasher.combine(key); hasher.combine(o[key]) }
        case .array(let a): hasher.combine(1); hasher.combine(a)
        case .string(let s): hasher.combine(2); hasher.combine(s)
        case .number(let n): hasher.combine(3); hasher.combine(n)
        case .bool(let b): hasher.combine(4); hasher.combine(b)
        case .null: hasher.combine(5)
        }
    }
}
