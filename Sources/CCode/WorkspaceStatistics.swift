import Foundation
import CCodeCore

extension AppStore {
    func refreshChangeStatistics(_ chat: ChatSession) {
        let previous = chat.workspaceStatisticsTask
        previous?.cancel()
        let operation = UUID(); chat.workspaceStatisticsID = operation
        let directory = chat.workspaceDirectory
        chat.changeStatistics = nil; chat.changeStatisticsError = nil
        chat.workspaceStatisticsTask = Task {
            await previous?.value
            guard !Task.isCancelled, !chat.closing, chat.workspaceStatisticsID == operation else { return }
            do {
                let values = try await chat.workspace.repository.changeStatistics(at: directory)
                guard !Task.isCancelled, !chat.closing, chat.workspaceStatisticsID == operation, chat.workspaceDirectory == directory else { return }
                chat.changeStatistics = values
            } catch {
                guard !Task.isCancelled, !chat.closing, chat.workspaceStatisticsID == operation, chat.workspaceDirectory == directory else { return }
                chat.changeStatisticsError = error.localizedDescription
            }
        }
    }
    func stopChangeStatistics(_ chat: ChatSession) async {
        chat.workspaceStatisticsID = nil
        chat.workspaceStatisticsTask?.cancel()
        await chat.workspaceStatisticsTask?.value
        chat.workspaceStatisticsTask = nil
    }
}
