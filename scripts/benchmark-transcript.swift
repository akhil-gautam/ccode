// Compile with the actual core: swiftc -O -parse-as-library -module-cache-path .build/benchmark-module-cache Sources/CCodeCore/*.swift scripts/benchmark-transcript.swift -o .build/benchmark-transcript
// Headless reducer evidence only: excludes ACP transport, Markdown and native layout.
import Foundation

@main struct TranscriptBenchmark {
    static func milliseconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
    }
    static func event(_ kind: String, _ value: JSONValue) -> JSONValue {
        ["sessionId": "benchmark", "update": value.merging(["sessionUpdate": .string(kind)])]
    }
    static func main() throws {
        let clock = ContinuousClock()
        for count in [1000, 3000, 6000] {
            var transcript = SessionTranscript(remoteID: "benchmark")
            let initial = (0..<count).flatMap { index in [
                event("agent_message_chunk", ["messageId": .string("message-\(index)"), "content": ["type": "text", "text": "A streamed assistant message."]]),
                event("tool_call", ["toolCallId": .string("tool-\(index)"), "title": "Read project file", "status": "in_progress"])
            ] }
            let updates = (0..<256).map { index in
                event("tool_call_update", ["toolCallId": .string("tool-\(index % 32)"), "status": "completed"])
            }
            let start = clock.now
            for update in initial { precondition(transcript.apply(update)) }
            let build = milliseconds(start.duration(to: clock.now))
            var batches: [Double] = []
            for _ in 0..<20 {
                let start = clock.now
                for update in updates { precondition(transcript.apply(update)) }
                batches.append(milliseconds(start.duration(to: clock.now)))
            }
            precondition(transcript.items.count == count * 2)
            for index in 0..<32 { precondition(transcript.items[index * 2 + 1].tool["status"] == "completed") }
            let sorted = batches.sorted()
            print(String(format: "rows=%d build_ms=%.3f update_batches=20x256 p50_ms=%.3f p95_ms=%.3f max_ms=%.3f", count * 2, build, sorted[9], sorted[18], sorted[19]))
            // Include copy/serialization in a separately reported number: the app saves value snapshots.
            let saveStart = clock.now
            let encoded = try JSONEncoder().encode(transcript)
            let restored = try JSONDecoder().decode(SessionTranscript.self, from: encoded)
            precondition(restored.items.count == count * 2)
            print(String(format: "rows=%d roundtrip_ms=%.3f json_bytes=%d", count * 2, milliseconds(saveStart.duration(to: clock.now)), encoded.count))
        }
    }
}
