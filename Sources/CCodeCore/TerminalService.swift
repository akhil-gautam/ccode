@preconcurrency import Foundation
import Darwin

public actor TerminalService {
    private struct Terminal {
        let process: Process
        let group: pid_t?
        let limit: Int
        var bytes = Data()
        var standardErrorBytes = Data()
        var truncated = false
        var exit: JSONValue?
        var drained = false
        var remainingReaders = 1
        var captureErrors = false
        var inputWriter: PipeWriter?
        var inputError: String?
        var inputComplete = true
        var waiters: [UUID: CheckedContinuation<JSONValue, any Error>] = [:]
    }
    private var terminals: [String: Terminal] = [:]
    public init() {}

    public func create(command: String, arguments: [String] = [], directory: String, environment: [String: String] = [:], byteLimit: Int = 1024 * 1024, captureStandardErrorSeparately: Bool = false, input: Data? = nil) throws -> String {
        try Task.checkCancellation()
        guard !command.isEmpty, byteLimit >= 0, terminals.count < 32, (input?.count ?? 0) <= 8 * 1024 * 1024 else { throw ACPError.workspace("Invalid terminal command/input/limit, or 32 terminals already open.") }
        let id = UUID().uuidString, child = Process(), pipe = Pipe()
        let errors = captureStandardErrorSeparately ? Pipe() : nil
        child.executableURL = URL(fileURLWithPath: command.hasPrefix("/") ? command : "/usr/bin/env")
        child.arguments = command.hasPrefix("/") ? arguments : ["--", command] + arguments
        child.currentDirectoryURL = URL(fileURLWithPath: directory)
        child.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let inputPipe = input == nil ? nil : Pipe()
        let inputWriter = try inputPipe.map { try PipeWriter($0.fileHandleForWriting) }
        child.standardInput = inputPipe ?? FileHandle.nullDevice
        child.standardOutput = pipe; child.standardError = errors ?? pipe
        child.terminationHandler = { [weak self] process in
            let exit: JSONValue = process.terminationReason == .uncaughtSignal
                ? ["signal": .string(String(process.terminationStatus))]
                : ["exitCode": .number(Double(process.terminationStatus))]
            Task { await self?.markExit(id, exit: exit) }
        }
        try child.run()
        try? inputPipe?.fileHandleForReading.close(); try? inputPipe?.fileHandleForWriting.close()
        terminals[id] = Terminal(process: child, group: ownedProcessGroup(child), limit: min(byteLimit, 4 * 1024 * 1024), remainingReaders: errors == nil ? 1 : 2, captureErrors: captureStandardErrorSeparately, inputWriter: inputWriter, inputComplete: input == nil)
        if let inputWriter, let input {
            try inputWriter.enqueue(input) { [weak self] result in
                inputWriter.close()
                let detail: String? = if case .failure(let error) = result { error.localizedDescription } else { nil }
                Task { await self?.markInputComplete(id, error: detail) }
            }
        }
        var streams = [(pipe.fileHandleForReading, false)]
        if let errors { streams.append((errors.fileHandleForReading, true)) }
        for (handle, standardError) in streams {
            DispatchQueue(label: "ccode.terminal.\(id).\(standardError ? "stderr" : "stdout")").async { [weak self] in
                let bridge = DispatchSemaphore(value: 0)
                var remainingAfterExit: Int?
                while let data = try? readPipe(handle, untilExit: child, remainingAfterExit: &remainingAfterExit), !data.isEmpty {
                    Task { await self?.append(data, id: id, standardError: standardError); bridge.signal() }
                    bridge.wait()
                }
                Task { await self?.markDrained(id) }
                try? handle.close()
            }
        }
        return id
    }

    public func output(_ id: String) throws -> JSONValue {
        guard let terminal = terminals[id] else { throw ACPError.workspace("Unknown terminal ID.") }
        var value: JSONValue = ["output": .string(String(decoding: terminal.bytes, as: UTF8.self)), "truncated": .bool(terminal.truncated)]
        if terminal.captureErrors { value["standardError"] = .string(String(decoding: terminal.standardErrorBytes, as: UTF8.self)) }
        if let error = terminal.inputError { value["inputError"] = .string(error) }
        if terminal.drained, let exit = terminal.exit { value["exitStatus"] = exit }
        return value
    }

    public func ownsProcess(_ id: String, pid: pid_t) -> Bool {
        guard let terminal = terminals[id], terminal.process.isRunning else { return false }
        if pid == terminal.process.processIdentifier { return true }
        return terminal.group.map { getpgid(pid) == $0 } ?? false
    }

    public func wait(_ id: String) async throws -> JSONValue {
        try Task.checkCancellation()
        guard let terminal = terminals[id] else { throw ACPError.workspace("Unknown terminal ID.") }
        if terminal.drained, let exit = terminal.exit { return exit }
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { terminals[id]?.waiters[waiter] = $0 }
        } onCancel: { Task { await self.cancelWait(id, waiter: waiter) } }
    }

    public func kill(_ id: String) async throws {
        guard let terminal = terminals[id] else { throw ACPError.workspace("Unknown terminal ID.") }
        terminal.inputWriter?.close(); await stopProcess(terminal.process, group: terminal.group)
    }
    public func release(_ id: String) async throws {
        guard let terminal = terminals.removeValue(forKey: id) else { throw ACPError.workspace("Unknown terminal ID.") }
        terminal.inputWriter?.close(); await stopProcess(terminal.process, group: terminal.group)
        for waiter in terminal.waiters.values { waiter.resume(throwing: ACPError.workspace("Terminal released.")) }
    }
    public func close() async {
        await withTaskGroup(of: Void.self) { group in
            for id in terminals.keys { group.addTask { try? await self.release(id) } }
        }
    }

    private func append(_ data: Data, id: String, standardError: Bool = false) {
        guard var terminal = terminals[id] else { return }
        var bytes = standardError ? terminal.standardErrorBytes : terminal.bytes
        bytes.append(data)
        if bytes.count > terminal.limit {
            terminal.truncated = true
            bytes = Data(bytes.suffix(terminal.limit))
            while let first = bytes.first, first & 0xc0 == 0x80 { bytes.removeFirst() }
        }
        if standardError { terminal.standardErrorBytes = bytes } else { terminal.bytes = bytes }
        terminals[id] = terminal
    }
    private func markExit(_ id: String, exit: JSONValue) {
        terminals[id]?.exit = exit
        completeIfReady(id)
    }
    private func markInputComplete(_ id: String, error: String?) {
        terminals[id]?.inputError = error; terminals[id]?.inputComplete = true; completeIfReady(id)
    }
    private func markDrained(_ id: String) {
        if let count = terminals[id]?.remainingReaders { terminals[id]?.remainingReaders = count - 1; terminals[id]?.drained = count <= 1 }
        completeIfReady(id)
    }
    private func completeIfReady(_ id: String) {
        guard var terminal = terminals[id] else { return }
        guard terminal.drained, terminal.inputComplete, let exit = terminal.exit else { return }
        let waiters = terminal.waiters.values
        terminal.waiters.removeAll()
        terminals[id] = terminal
        for waiter in waiters { waiter.resume(returning: exit) }
    }
    private func cancelWait(_ id: String, waiter: UUID) {
        terminals[id]?.waiters.removeValue(forKey: waiter)?.resume(throwing: CancellationError())
    }
}
