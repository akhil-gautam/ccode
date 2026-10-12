@preconcurrency import Foundation
import Darwin

// One bounded writer queue keeps pipe backpressure off the protocol actor.
public final class PipeWriter: @unchecked Sendable {
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "ccode.acp.stdin")
    private let lock = NSLock()
    private var closed = false
    private var queuedBytes = 0
    public init(_ handle: FileHandle) throws {
        descriptor = dup(handle.fileDescriptor)
        guard descriptor >= 0 else { throw POSIXError(.EBADF) }
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0, fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0, fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            Darwin.close(descriptor); throw POSIXError(.EIO)
        }
    }
    public func enqueue(_ data: Data, completion: @escaping @Sendable (Result<Void, any Error>) -> Void) throws {
        try lock.withLock {
            guard !closed else { throw ACPError.disconnected("Process input is closed.") }
            guard data.count <= 8 * 1024 * 1024, queuedBytes + data.count <= 16 * 1024 * 1024 else { throw ACPError.protocolViolation("Process input queue exceeds its memory limit.") }
            queuedBytes += data.count
        }
        queue.async { [self] in
            defer { lock.withLock { queuedBytes -= data.count } }
            do {
                try data.withUnsafeBytes { bytes in
                    var cursor = 0
                    while cursor < bytes.count {
                        guard !lock.withLock({ closed }) else { throw ACPError.disconnected("Process input is closed.") }
                        let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: cursor), bytes.count - cursor)
                        if count > 0 { cursor += count; continue }
                        if count < 0 && errno == EINTR { continue }
                        if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                            var state = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                            _ = poll(&state, 1, 50); continue
                        }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPIPE)
                    }
                }
                completion(.success(()))
            } catch { completion(.failure(error)) }
        }
    }
    public func close() {
        let first = lock.withLock { let first = !closed; closed = true; return first }
        if first { queue.async { [descriptor] in Darwin.close(descriptor) } }
    }
    deinit { close() }
}

func ownedProcessGroup(_ process: Process) -> pid_t? {
    let pid = process.processIdentifier
    return getpgid(pid) == pid ? pid : nil
}

func stopProcess(_ process: Process, group: pid_t?) async {
    if let group { Darwin.kill(-group, SIGTERM) }
    else if process.isRunning { process.terminate() }
    // Cleanup must finish before the application exits, even if its task was cancelled.
    await Task.detached {
        let pid = process.processIdentifier
        // Group membership may disappear before the leader PID is reaped.
        func alive() -> Bool { Darwin.kill(pid, 0) == 0 || (group.map { Darwin.kill(-$0, 0) == 0 } ?? false) }
        for _ in 0..<20 {
            if !alive() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if let group { Darwin.kill(-group, SIGKILL) }
        else if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        for _ in 0..<20 {
            if !alive() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }.value
}
