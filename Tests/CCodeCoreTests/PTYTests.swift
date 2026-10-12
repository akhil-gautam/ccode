import XCTest
import Darwin
import SwiftTerm
import AppKit
@testable import CCode

private actor TerminalOutput {
    var text = ""
    var exit: Int32?
    func append(_ data: Data) { text += String(decoding: data, as: UTF8.self) }
    func ended(_ status: Int32) { exit = status }
}

final class PTYTests: XCTestCase, @unchecked Sendable {
    private func wait(_ output: TerminalOutput, for text: String) async throws {
        for _ in 0..<200 {
            if await output.text.contains(text) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Missing terminal output: \(text)")
    }
    func testInteractiveInputResizeDirectoryAndExit() async throws {
        let output = TerminalOutput()
        let terminal = try PTYSession(executable: "/bin/sh", arguments: ["-c", "test -t 0 && printf 'TTY_READY\\n'; pwd; read answer; stty size; printf 'ANSWER:%s\\n' \"$answer\"; exit 7"], directory: "/private/tmp", environment: ProcessInfo.processInfo.environment, onData: { await output.append($0) }, onExit: { await output.ended($0) })
        try await wait(output, for: "TTY_READY")
        terminal.resize(columns: 120, rows: 40)
        try terminal.send(Data("héllo\n".utf8))
        try await wait(output, for: "ANSWER:héllo")
        await terminal.wait()
        let text = await output.text, status = await output.exit
        XCTAssertTrue(text.contains("/private/tmp"))
        XCTAssertTrue(text.contains("40 120"))
        XCTAssertEqual(status, 7)
    }
    func testInteractiveZshAcceptsReturn() async throws {
        let output = TerminalOutput()
        var environment = ProcessInfo.processInfo.environment; environment["PS1"] = "READY> "
        let terminal = try PTYSession(executable: "/bin/zsh", arguments: ["-f", "-i"], directory: "/private/tmp", environment: environment, onData: { await output.append($0) }, onExit: { await output.ended($0) })
        try await wait(output, for: "READY>")
        try terminal.send(Data("printf '%s:%s\\n' RESULT 42\r".utf8))
        try await wait(output, for: "RESULT:42")
        await terminal.close()
    }
    func testCloseKillsResistantBackgroundJobAndReturns() async throws {
        let output = TerminalOutput()
        let terminal = try PTYSession(executable: "/bin/sh", arguments: ["-c", "trap '' TERM HUP; (trap '' TERM HUP; while :; do sleep 1; done) & printf 'CHILD:%s\\n' $!; while :; do sleep 1; done"], directory: "/private/tmp", environment: ProcessInfo.processInfo.environment, onData: { await output.append($0) }, onExit: { await output.ended($0) })
        try await wait(output, for: "CHILD:")
        let text = await output.text
        let pid = try XCTUnwrap(Int32(text.components(separatedBy: "CHILD:").last!.trimmingCharacters(in: .whitespacesAndNewlines)))
        await terminal.close()
        for _ in 0..<100 { if kill(pid, 0) != 0 { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotEqual(kill(pid, 0), 0)
        XCTAssertNotEqual(kill(terminal.pid, 0), 0)
    }
    func testParentExitDrainsOutputAndCleansSeparateJobGroup() async throws {
        let output = TerminalOutput()
        let script = """
        import os, signal, time
        child = os.fork()
        if child == 0:
            signal.signal(signal.SIGHUP, signal.SIG_IGN)
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            os.setpgid(0, 0)
            print('JOB:%d' % os.getpid(), flush=True)
            while True: time.sleep(1)
        time.sleep(.2)
        print('FINAL:' + 'x' * 32768, flush=True)
        os._exit(9)
        """
        let terminal = try PTYSession(executable: "/usr/bin/python3", arguments: ["-c", script], directory: "/private/tmp", environment: ProcessInfo.processInfo.environment, onData: { await output.append($0) }, onExit: { await output.ended($0) })
        try await wait(output, for: "JOB:")
        let text = await output.text
        let pid = try XCTUnwrap(Int32(text.components(separatedBy: "JOB:").last!.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(getsid(pid), terminal.pid)
        XCTAssertEqual(getpgid(pid), pid)
        await terminal.wait()
        let final = await output.text, status = await output.exit
        XCTAssertTrue(final.contains("FINAL:" + String(repeating: "x", count: 32768)))
        XCTAssertEqual(status, 9)
        for _ in 0..<100 { if kill(pid, 0) != 0 { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotEqual(kill(pid, 0), 0)
    }
    func testNativeEngineParsesANSIAndFragmentedUnicode() throws {
        let delegate = TerminalDecoder()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 80, rows: 25, scrollback: 1000))
        let bytes = Array("\u{1b}[31mé\u{1b}[0m\r\nold\r\u{1b}[2Knew".utf8)
        for byte in bytes { terminal.feed(buffer: [byte][...]) }
        let first = try XCTUnwrap(terminal.getLine(row: 0))
        XCTAssertEqual(first.translateToString(trimRight: true), "é")
        XCTAssertEqual(first[0].attribute.fg, .ansi256(code: 1))
        XCTAssertEqual(terminal.getLine(row: 1)?.translateToString(trimRight: true), "new")
    }
    @MainActor func testNativeViewPreservesOutputThroughLayoutProposals() throws {
        let view = NativeTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400), font: .monospacedSystemFont(ofSize: 12, weight: .regular), options: TerminalOptions(cursorStyle: .steadyBlock, scrollback: 1000))
        view.feed(text: "COMMAND>\r\nRESULT:42\r\nPROMPT_READY> ")
        view.setFrameSize(NSSize(width: 300, height: 0))
        view.setFrameSize(NSSize(width: 300, height: 700))
        let terminal = view.getTerminal()
        let lines = (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }
        XCTAssertTrue(lines.joined().contains("PROMPT_READY>"), lines.description)
        XCTAssertTrue(lines.joined().contains("RESULT:42"), lines.description)
        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityRole(), .textArea)
        XCTAssertTrue((view.accessibilityValue() as? String)?.contains("PROMPT_READY>") == true)
    }
}

private final class TerminalDecoder: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
