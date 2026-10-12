import Foundation
import CCodeCore

extension AppStore {
    func startPreview(_ chat: ChatSession, configuration: PreviewLaunchConfiguration) async throws {
        guard canDeliver(chat), !chat.previewActive, !chat.previewStarting, !checkpointRestorationBlocks(chat) else { throw ACPError.workspace("Stop the current preview and finish workspace changes before starting a dev server.") }
        let operation = UUID()
        chat.previewOperation = operation; chat.previewStarting = true; chat.previewActive = true
        chat.transcript.previewLaunch = configuration
        let task = Task { @MainActor in
            defer { if chat.previewOperation == operation { chat.previewStarting = false; chat.previewTask = nil } }
            do {
                try await persistDelivery(chat); try Task.checkCancellation()
                try await chat.previewServer.start(configuration)
                guard chat.previewOperation == operation, !chat.closing else { throw CancellationError() }
                guard let url = URL(string: configuration.url) else { throw ACPError.workspace("Invalid preview URL.") }
                let browser = chat.browserWorkspace
                let tab: BrowserTab
                if let existing = browser.tabs.first(where: { BrowserWorkspace.origin($0.url) == BrowserWorkspace.origin(url) && !$0.manualLogin }) { tab = existing }
                else { tab = try browser.open(url) }
                browser.allowAgent(on: tab.id); try browser.navigate(tab, to: url)
                setPane("browser", for: chat)
                chat.previewMonitor = Task { @MainActor in
                    while chat.previewOperation == operation, !Task.isCancelled {
                        let phase = await chat.previewServer.currentPhase
                        if phase == .failed || phase == .stopped { chat.previewActive = false; chat.previewMonitor = nil; break }
                        do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
                    }
                }
            } catch {
                await chat.previewServer.stop()
                if chat.previewOperation == operation { chat.previewActive = false }
                throw error
            }
        }
        chat.previewTask = task
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    func stopPreview(_ chat: ChatSession) async {
        let pending = chat.previewTask, monitor = chat.previewMonitor
        chat.previewOperation = nil; pending?.cancel(); monitor?.cancel()
        await chat.previewServer.stop(); _ = try? await pending?.value; await monitor?.value
        chat.previewTask = nil; chat.previewMonitor = nil; chat.previewStarting = false; chat.previewActive = false
    }
}
