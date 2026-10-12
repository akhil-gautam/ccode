import SwiftUI
import Observation
import Foundation
import CCodeCore
@preconcurrency import Speech
@preconcurrency import AVFoundation

enum DictationDestination: Equatable { case home, chat(UUID), sideQuestion(UUID) }
enum SpeechCaptureEvent: Sendable { case partial(String), final(String), failure(String) }
@MainActor protocol SpeechCaptureEngine: AnyObject {
    func start(_ receive: @escaping @Sendable (SpeechCaptureEvent) -> Void) async throws
    func finish()
    func cancel()
}

@Observable @MainActor final class NativeDictation {
    enum State { case idle, requesting, listening, finishing, review, failed }
    private(set) var state: State = .idle
    private(set) var destination: DictationDestination?
    private(set) var text = ""
    private(set) var error: String?
    @ObservationIgnored private let engineFactory: @MainActor () -> any SpeechCaptureEngine
    @ObservationIgnored private let finishTimeout: Duration
    @ObservationIgnored private var engine: (any SpeechCaptureEngine)?
    @ObservationIgnored private var operation: UUID?
    @ObservationIgnored private var timeout: Task<Void, Never>?
    init(engineFactory: @escaping @MainActor () -> any SpeechCaptureEngine = { AppleSpeechEngine() }, finishTimeout: Duration = .seconds(5)) { self.engineFactory = engineFactory; self.finishTimeout = finishTimeout }
    var capturing: Bool { [.requesting, .listening, .finishing].contains(state) }
    func begin(_ destination: DictationDestination) async {
        guard state == .idle else { return }
        let id = UUID(), engine = engineFactory()
        self.engine = engine; operation = id; self.destination = destination; state = .requesting; text = ""; error = nil
        do {
            try await engine.start { [weak self] event in Task { @MainActor [weak self] in self?.receive(event, operation: id) } }
            guard operation == id else { engine.cancel(); return }
            // A recognizer can emit a final result before start returns.
            if state == .requesting { state = .listening }
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                if self?.operation == id { self?.finish() }
            }
        } catch {
            guard operation == id else { engine.cancel(); return }
            self.error = error.localizedDescription; release(); state = text.isEmpty ? .failed : .review
        }
    }
    private func receive(_ event: SpeechCaptureEvent, operation id: UUID) {
        guard operation == id, capturing else { return }
        switch event {
        case .partial(let text): self.text = String(text.prefix(32 * 1024))
        case .final(let text): self.text = String(text.prefix(32 * 1024)); release(); state = self.text.isEmpty ? .idle : .review; if state == .idle { destination = nil }
        case .failure(let error): self.error = error; release(); state = text.isEmpty ? .failed : .review
        }
    }
    func finish() {
        guard state == .listening else { return }
        state = .finishing; engine?.finish(); timeout?.cancel()
        let id = operation
        timeout = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: finishTimeout) } catch { return }
            guard operation == id, state == .finishing else { return }
            error = "Recognition did not return a final result. Review the captured text."
            release(); state = text.isEmpty ? .failed : .review
        }
    }
    func insertion(for destination: DictationDestination, current: String) -> String? {
        guard self.destination == destination, state == .review, !text.isEmpty else { return nil }
        let joined = current.isEmpty ? text : current + "\n" + text
        guard joined.utf8.count < PromptAttachment.promptLimit else { error = "The draft is too large. Shorten it before inserting dictation."; return nil }
        cancel(); return joined
    }
    func cancel() { release(); destination = nil; state = .idle; text = ""; error = nil }
    func cancel(for destination: DictationDestination) { if self.destination == destination { cancel() } }
    private func release() { operation = nil; timeout?.cancel(); timeout = nil; engine?.cancel(); engine = nil }
}

@MainActor private final class AppleSpeechEngine: SpeechCaptureEngine {
    private var operation = UUID()
    private var audio: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapped = false
    func start(_ receive: @escaping @Sendable (SpeechCaptureEvent) -> Void) async throws {
        let id = UUID(); operation = id
        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.supportsOnDeviceRecognition else { throw ACPError.workspace("On-device dictation is unavailable for this language. Use keyboard input or macOS Dictation.") }
        let status = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0.rawValue) } }
        guard operation == id else { throw CancellationError() }
        guard status == SFSpeechRecognizerAuthorizationStatus.authorized.rawValue else { throw ACPError.workspace("Speech permission is unavailable. Enable ccode in System Settings → Privacy & Security → Speech Recognition.") }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw ACPError.workspace("Microphone permission is unavailable. Enable ccode in System Settings → Privacy & Security → Microphone.") }
        guard operation == id else { throw CancellationError() }
        guard recognizer.isAvailable else { throw ACPError.workspace("On-device dictation is temporarily unavailable.") }
        let audio = AVAudioEngine(), request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true
        self.audio = audio; self.request = request; self.recognizer = recognizer
        let input = audio.inputNode, format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw ACPError.workspace("No working microphone is available.") }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        tapped = true
        task = recognizer.recognitionTask(with: request) { result, error in
            if let result { receive(result.isFinal ? .final(result.bestTranscription.formattedString) : .partial(result.bestTranscription.formattedString)) }
            if let error, result?.isFinal != true { receive(.failure(error.localizedDescription)) }
        }
        audio.prepare(); try audio.start()
    }
    func finish() { audio?.stop(); request?.endAudio() }
    func cancel() {
        operation = UUID()
        if let audio { audio.stop(); if tapped { audio.inputNode.removeTap(onBus: 0) } }
        tapped = false
        request?.endAudio(); task?.cancel(); task = nil; request = nil; recognizer = nil; audio = nil
    }
}

struct DictationButton: View {
    @Bindable var capture: NativeDictation
    let destination: DictationDestination
    var body: some View {
        Button { Task { await capture.begin(destination) } } label: { Image(systemName: "mic") }
            .buttonStyle(.plain).disabled(capture.state != .idle)
            .help(capture.destination != nil && capture.destination != destination ? "Finish or discard dictation in its original draft, or press Esc to discard it." : "Dictate on this device")
            .accessibilityLabel("Start dictation")
    }
}

struct DictationPreview: View {
    @Bindable var capture: NativeDictation
    let destination: DictationDestination
    @Binding var draft: String
    var body: some View {
        if capture.destination == destination {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if capture.capturing { ProgressView().controlSize(.small) }
                    Text(capture.state == .requesting ? "Preparing dictation…" : capture.state == .listening ? "Listening…" : capture.state == .finishing ? "Finishing…" : "Dictation").fontWeight(.medium)
                    Spacer()
                    if capture.state == .listening { Button("Finish") { capture.finish() } }
                    if capture.state == .review { Button("Insert") { if let text = capture.insertion(for: destination, current: draft) { draft = text } } }
                    Button(capture.capturing ? "Cancel" : "Discard") { capture.cancel() }
                }
                if !capture.text.isEmpty { Text(capture.text).lineLimit(4).textSelection(.enabled) }
                if let error = capture.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            }.font(.caption).padding(12).background(Palette.muted, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
