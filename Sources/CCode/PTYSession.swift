@preconcurrency import Foundation
@preconcurrency import SwiftTerm
import Darwin
import CCodeCore

// A PTY has its own Unix session: foreground and background jobs may have
// different process groups, so closing it must clean up the entire session.
final class PTYSession: @unchecked Sendable {
    let pid: pid_t
    private let control: PTYControl
    private let writer: PipeWriter
    private let completion: Task<Void, Never>

    init(executable: String, arguments: [String], directory: String, environment: [String: String],
         onData: @escaping @Sendable (Data) async -> Void,
         onExit: @escaping @Sendable (Int32) async -> Void) throws {
        var isDirectory: ObjCBool = false
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable),
              FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue,
              !([executable, directory] + arguments + environment.flatMap { [$0.key, $0.value] }).contains(where: { $0.contains("\0") }),
              !environment.keys.contains(where: { $0.isEmpty || $0.contains("=") }) else { throw ACPError.workspace("Invalid terminal executable, folder or environment.") }
        var env = environment; env["TERM"] = "xterm-256color"; env["COLORTERM"] = "truecolor"
        var size = winsize(ws_row: 25, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        guard let child = PseudoTerminalHelpers.fork(andExec: executable, args: [executable] + arguments, env: env.map { "\($0.key)=\($0.value)" }, currentDirectory: directory, desiredWindowSize: &size) else { throw POSIXError(.EIO) }
        pid = child.pid
        let handle = FileHandle(fileDescriptor: child.masterFd, closeOnDealloc: false)
        do {
            guard fcntl(child.masterFd, F_SETFD, FD_CLOEXEC) == 0 else { throw POSIXError(.EIO) }
            writer = try PipeWriter(handle)
        } catch {
            Darwin.kill(child.pid, SIGKILL); Darwin.close(child.masterFd)
            var status: Int32 = 0; while waitpid(child.pid, &status, 0) < 0 && errno == EINTR {}
            throw error
        }
        let control = PTYControl(descriptor: child.masterFd)
        self.control = control
        let writer = self.writer
        completion = Task {
            let status: Int32 = await withCheckedContinuation { continuation in
                DispatchQueue(label: "ccode.pty.\(child.pid)", qos: .userInitiated).async {
                    let status = Self.read(pid: child.pid, control: control, onData: onData)
                    writer.close()
                    control.finish()
                    continuation.resume(returning: status)
                }
            }
            await onExit(status)
        }
    }
    func send(_ data: Data) throws { try writer.enqueue(data) { _ in } }
    func resize(columns: Int, rows: Int) { control.resize(columns: columns, rows: rows) }
    func wait() async { await completion.value }
    func close() async { control.stop(); writer.close(); await completion.value }
    deinit { control.stop(); writer.close() }

    private static func exited(_ pid: pid_t) -> Bool {
        var info = siginfo_t()
        return waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == pid
    }
    private static func members(_ session: pid_t) -> [pid_t] {
        let capacity = max(1024, min(65536, proc_listallpids(nil, 0) + 512))
        var pids = [pid_t](repeating: 0, count: Int(capacity))
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return pids.prefix(max(0, min(Int(count), pids.count))).filter { $0 > 0 && getsid($0) == session }
    }
    private static func read(pid: pid_t, control: PTYControl, onData: @escaping @Sendable (Data) async -> Void) -> Int32 {
        let fd = control.descriptor
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var remaining: Int?
        while !control.stopped {
            if remaining == nil && exited(pid) { remaining = max(0, Int(PseudoTerminalHelpers.availableBytes(fd: fd).size)) }
            if remaining == 0 { break }
            var pollState = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollState, 1, 100)
            if ready < 0 && errno == EINTR { continue }
            if ready < 0 { break }
            if ready == 0 { continue }
            let count = Darwin.read(fd, &buffer, min(buffer.count, remaining ?? buffer.count))
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { continue }
            guard count > 0 else { break }
            if remaining != nil { remaining! -= count }
            let data = Data(buffer.prefix(count)), delivered = DispatchSemaphore(value: 0)
            Task { await onData(data); delivered.signal() }
            delivered.wait() // Backpressure: at most one 16 KB chunk awaits the view.
        }
        // Closing the master releases a shell blocked in terminal teardown.
        // Waiting first can deadlock after forced Close stops draining output.
        control.finish()
        // Keep the root unreaped until its jobs are signalled, preventing PID reuse.
        for member in members(pid) { Darwin.kill(member, SIGTERM) }
        for _ in 0..<20 {
            if exited(pid) && members(pid).allSatisfy({ $0 == pid }) { break }
            usleep(50_000)
        }
        for member in members(pid) { Darwin.kill(member, SIGKILL) }
        if !exited(pid) { Darwin.kill(pid, SIGKILL) }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }
}

private final class PTYControl: @unchecked Sendable {
    let descriptor: Int32
    private let lock = NSLock()
    private var closing = false
    private var finished = false
    init(descriptor: Int32) { self.descriptor = descriptor }
    var stopped: Bool { lock.withLock { closing } }
    func stop() { lock.withLock { closing = true } }
    func finish() { lock.withLock { guard !finished else { return }; closing = true; finished = true; Darwin.close(descriptor) } }
    func resize(columns: Int, rows: Int) {
        guard (1...1000).contains(columns), (1...1000).contains(rows) else { return }
        lock.withLock {
            guard !closing, !finished else { return }
            var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
            _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: descriptor, windowSize: &size)
        }
    }
}
