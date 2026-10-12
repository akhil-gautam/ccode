import XCTest
import Foundation
import SwiftUI
import AppKit
import CCodeCore
@testable import CCode

@MainActor private final class FakeSpeechEngine: SpeechCaptureEngine {
    var receive: (@Sendable (SpeechCaptureEvent) -> Void)?
    var suspendStart = false
    var startGate: CheckedContinuation<Void, Never>?
    var startError: Error?
    var cancels = 0
    var finishes = 0
    func start(_ receive: @escaping @Sendable (SpeechCaptureEvent) -> Void) async throws { self.receive = receive; if suspendStart { await withCheckedContinuation { startGate = $0 } }; if let startError { throw startError } }
    func finish() { finishes += 1 }
    func cancel() { cancels += 1 }
}

@MainActor private final class FakeSpeechFactory { var current: FakeSpeechEngine; init(_ current: FakeSpeechEngine) { self.current = current } }

final class NativeCapabilityTests: XCTestCase {
    @MainActor func testDictationNeverChangesDraftOrSendsAndInsertionKeepsCurrentDraft() async throws {
        let engine = FakeSpeechEngine(), capture = NativeDictation(engineFactory: { engine }), target = DictationDestination.chat(UUID())
        await capture.begin(target)
        engine.receive?(.partial("hello")); await settle()
        XCTAssertEqual(capture.text, "hello"); XCTAssertEqual(capture.state, .listening)
        engine.receive?(.final("hello world")); await settle()
        XCTAssertEqual(capture.state, .review); XCTAssertEqual(engine.cancels, 1)
        XCTAssertNil(capture.insertion(for: .chat(UUID()), current: "Different chat"))
        XCTAssertEqual(capture.insertion(for: target, current: "New unsent draft"), "New unsent draft\nhello world")
        XCTAssertEqual(capture.state, .idle)
    }
    @MainActor func testCancelledCaptureCannotUpdateAnotherDestination() async throws {
        let a = FakeSpeechEngine(), b = FakeSpeechEngine(), factory = FakeSpeechFactory(a)
        let capture = NativeDictation(engineFactory: { factory.current }), original = DictationDestination.chat(UUID()), other = DictationDestination.sideQuestion(UUID())
        await capture.begin(original); let obsolete = a.receive
        capture.cancel(); factory.current = b; await capture.begin(other)
        obsolete?(.final("stale private text")); await settle()
        XCTAssertEqual(capture.destination, other); XCTAssertTrue(capture.text.isEmpty)
        b.receive?(.final("new text")); await settle()
        XCTAssertEqual(capture.insertion(for: other, current: ""), "new text")
    }
    @MainActor func testPermissionFailureAndRecognitionFailureReleaseAudioAndRetainPartial() async throws {
        let engine = FakeSpeechEngine(); engine.startError = ACPError.workspace("Microphone denied")
        let capture = NativeDictation(engineFactory: { engine }), target = DictationDestination.home
        await capture.begin(target)
        XCTAssertEqual(capture.state, .failed); XCTAssertTrue(capture.error?.contains("denied") == true); XCTAssertEqual(engine.cancels, 1)
        capture.cancel(); engine.startError = nil; await capture.begin(target)
        engine.receive?(.partial("Keep this text")); await settle()
        engine.receive?(.failure("Recognition disconnected")); await settle()
        XCTAssertEqual(capture.state, .review); XCTAssertEqual(capture.text, "Keep this text")
        XCTAssertEqual(capture.insertion(for: target, current: "Draft"), "Draft\nKeep this text")
    }
    @MainActor func testStopWaitsForFinalAndRejectsConcurrentCaptureWithoutStealingOwner() async throws {
        let engine = FakeSpeechEngine(), capture = NativeDictation(engineFactory: { engine }), target = DictationDestination.chat(UUID())
        await capture.begin(target); await capture.begin(.home)
        XCTAssertEqual(capture.destination, target)
        capture.finish(); XCTAssertEqual(capture.state, .finishing); XCTAssertEqual(engine.finishes, 1)
        engine.receive?(.final("Finished")); await settle()
        XCTAssertEqual(capture.state, .review); XCTAssertEqual(capture.text, "Finished")
        capture.cancel(); XCTAssertEqual(capture.state, .idle)
    }
    @MainActor func testCancellationDuringPermissionWaitCannotRestartMicrophoneOrCancelNewOwner() async throws {
        let a = FakeSpeechEngine(), b = FakeSpeechEngine(), factory = FakeSpeechFactory(a); a.suspendStart = true
        let capture = NativeDictation(engineFactory: { factory.current }), old = DictationDestination.chat(UUID()), current = DictationDestination.chat(UUID())
        let waiting = Task { await capture.begin(old) }; await settle()
        XCTAssertEqual(capture.state, .requesting)
        capture.cancel(); factory.current = b; await capture.begin(current)
        a.startGate?.resume(); await waiting.value
        a.receive?(.final("late")); await settle()
        XCTAssertEqual(capture.destination, current); XCTAssertEqual(capture.state, .listening); XCTAssertEqual(b.cancels, 0)
        capture.cancel()
    }
    @MainActor func testFinishingTimeoutPreservesPartialWithoutLeavingAudioRunning() async throws {
        let engine = FakeSpeechEngine(), capture = NativeDictation(engineFactory: { engine }, finishTimeout: .milliseconds(20))
        await capture.begin(.home); engine.receive?(.partial("Captured partial")); await settle()
        capture.finish(); try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(capture.state, .review); XCTAssertEqual(capture.text, "Captured partial"); XCTAssertEqual(engine.cancels, 1)
        XCTAssertNotNil(capture.error); capture.cancel()
    }
    @MainActor func testOtherChatStopPreservesCaptureAndOwningArchiveOrShutdownReleasesIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-dictation-owner-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(directory: root.appendingPathComponent("data")), engine = FakeSpeechEngine()
        store.dictation = NativeDictation(engineFactory: { engine })
        await store.create(path: root.path, worktree: false); let a = try XCTUnwrap(store.selected)
        await store.create(path: root.path, worktree: false); let b = try XCTUnwrap(store.selected)
        await store.dictation.begin(.chat(a.id)); store.stop(b)
        XCTAssertEqual(store.dictation.destination, .chat(a.id)); XCTAssertEqual(engine.cancels, 0)
        await store.archive(a.id); XCTAssertEqual(store.dictation.state, .idle); XCTAssertEqual(engine.cancels, 1)
        await store.dictation.begin(.home); await store.shutdown()
        XCTAssertEqual(store.dictation.state, .idle); XCTAssertEqual(engine.cancels, 2)
    }
    @MainActor func testReviewControlsFitNarrowLightAndDarkAndOversizedDraftKeepsBuffer() async throws {
        let engine = FakeSpeechEngine(), capture = NativeDictation(engineFactory: { engine })
        await capture.begin(.home); engine.receive?(.final(String(repeating: "Dictated text. ", count: 100))); await settle()
        for scheme in [ColorScheme.light, .dark] {
            let view = NSHostingView(rootView: DictationPreview(capture: capture, destination: .home, draft: .constant("Independent draft")).frame(width: 360).preferredColorScheme(scheme))
            view.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(view.fittingSize.width, 361); XCTAssertLessThanOrEqual(view.fittingSize.height, 280)
        }
        XCTAssertNil(capture.insertion(for: .home, current: String(repeating: "x", count: PromptAttachment.promptLimit)))
        XCTAssertEqual(capture.state, .review); XCTAssertFalse(capture.text.isEmpty)
        capture.cancel()
    }
    @MainActor private func settle() async { for _ in 0..<4 { await Task.yield() }; try? await Task.sleep(for: .milliseconds(10)) }
}
