import AppKit
import Observation
import CCodeCore

struct ComputerReadiness: Equatable {
    let accessibility: Bool
    let screenRecording: Bool
    var ready: Bool { accessibility && screenRecording }
}
@MainActor protocol ComputerEngine: AnyObject {
    var readiness: ComputerReadiness { get }
    func applications() -> [ComputerApplication]
    func perform(_ action: ComputerAction, app: ComputerApplication) async throws -> JSONValue
    func reset()
}
extension ComputerEngine { func reset() {} }
@MainActor @Observable final class ComputerWorkspace {
    @ObservationIgnored let engine: any ComputerEngine
    private(set) var grants: [String: ComputerApplication] = [:]
    private(set) var active = false
    private(set) var activity = ""
    var error: String?
    @ObservationIgnored private var epoch=UUID()
    @ObservationIgnored private var operation: Task<JSONValue, any Error>?
    init(engine: any ComputerEngine = MacComputerEngine()) { self.engine=engine }
    var readiness: ComputerReadiness { engine.readiness }
    var applications: [ComputerApplication] { engine.applications().filter { $0.id != "dev.ccode.native" } }
    func allow(_ appID: String) { if let app=applications.first(where:{ $0.id == appID }) { grants[appID]=app } }
    func revoke(_ appID: String) { grants.removeValue(forKey:appID); cancel() }
    func cancel() { epoch=UUID();operation?.cancel();operation=nil;active=false;activity="";engine.reset() }
    func stop() { grants.removeAll();cancel() }
    func perform(_ action: ComputerAction) async throws -> JSONValue {
        try Task.checkCancellation()
        if action.name == "computer_applications" { return ["apps":.array(applications.map { ["app":.string($0.id),"name":.string($0.name),"tier":.string(ComputerTier.forApp($0.id).rawValue),"allowed":.bool(grants[$0.id] == $0)] })] }
        guard let app=grants[action.appID],applications.contains(app) else { throw ACPError.workspace("Allow this application in the Computer pane first. Access expires when the agent disconnects or you press Stop control.") }
        guard readiness.ready else { throw ACPError.workspace("Computer control needs macOS Accessibility and Screen Recording permission. Check the Computer pane.") }
        guard !active else { throw ACPError.workspace("Another computer action is in progress.") }
        let owner=epoch;active=true;activity="\(action.name.replacingOccurrences(of:"computer_",with:"")) · \(app.name)";error=nil
        let task=Task { try await engine.perform(action,app:app) }; operation=task
        defer { if owner == epoch { active=false;operation=nil;activity="" } }
        do {
            let result=try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation(); guard owner == epoch,grants[app.id] == app,applications.contains(app) else { throw CancellationError() };return result
        } catch { if owner == epoch,self.error == nil { self.error=error.localizedDescription };throw error }
    }
}
