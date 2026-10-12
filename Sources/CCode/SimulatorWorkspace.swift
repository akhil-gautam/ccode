import Foundation
import Observation
import CCodeCore

@MainActor @Observable final class SimulatorWorkspace {
    var devices: [SimulatorDevice] = []
    var device: SimulatorDevice?
    var bundle = ""
    var allowed = false
    var bootedByApp = false
    var active = false
    var activity = ""
    var error: String?
    var image: Data?
    var inspection = ""
    @ObservationIgnored var epoch=UUID()
    @ObservationIgnored var bootTask: Task<Bool, any Error>?
    @ObservationIgnored var operation: Task<JSONValue, any Error>?
    @ObservationIgnored let service: SimulatorService
    init(service: SimulatorService) { self.service=service }
    func cancel() { epoch=UUID();bootTask?.cancel();operation?.cancel();operation=nil;active=false;activity="" }
    func refreshDevices() async { do { devices=try await service.devices();error=devices.isEmpty ? "No iOS simulator is installed. In Xcode → Settings → Components, install an iOS runtime, then refresh.":nil } catch { self.error="Xcode simulator tools are unavailable. \(error.localizedDescription)" } }
    func capture() async throws -> Data {
        guard let id=device?.id else { throw ACPError.workspace("Attach a simulator first.") }
        let owner=epoch,data=try await service.screenshot(id)
        guard epoch==owner,device?.id==id else { throw CancellationError() };image=data;return data
    }
    func perform(_ action: SimulatorAction,workspace:Workspace) async throws -> JSONValue {
        try Task.checkCancellation()
        guard allowed,let device else { throw ACPError.workspace("Allow agent access to this device in the Simulator pane first.") }
        guard !active else { throw ACPError.workspace("A simulator operation is in progress.") }
        let owner=epoch;active=true;activity=action.name.replacingOccurrences(of:"simulator_",with:"");error=nil
        let bundle=self.bundle,service=self.service
        let task=Task { @MainActor [weak self] in
            switch action.name {
            case "simulator_build":
                let output=try await service.build(device.id,project:action.arguments["project"].string,scheme:action.arguments["scheme"].string,workspace:workspace)
                let products=workspace.root+"/.ccode/simulator-build/"+device.id+"/Build/Products/Debug-iphonesimulator"
                let response:JSONValue=["output":.string(String(output.suffix(16000))),"products":.string(products)]
                return response
            case "simulator_install": _=try await service.install(device.id,app:action.arguments["app"].string,workspace:workspace);return ["state":"installed"]
            case "simulator_launch":
                let selected=action.arguments["bundle"].string
                guard selected.count<=256,selected.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-".contains($0)) }) else { throw ACPError.workspace("Invalid application bundle identifier.") }
                let result=try await service.command(["launch","--terminate-running-process",device.id,selected]);try Task.checkCancellation()
                if self?.epoch==owner { self?.bundle=selected };return ["output":.string(result),"bundle":.string(selected)]
            case "simulator_screenshot":
                let data=try await service.screenshot(device.id)
                if self?.epoch==owner { self?.image=data }
                return ["content":[["type":"image","mimeType":"image/jpeg","data":.string(data.base64EncodedString())]]]
            case "simulator_logs":return ["output":.string(try await service.command(["spawn",device.id,"log","show","--style","compact","--last","1m","--predicate","process == " + String(reflecting:bundle.split(separator:".").last.map(String.init) ?? "")],timeout:.seconds(30)))]
            case "simulator_open_url":return ["output":.string(try await service.command(["openurl",device.id,action.arguments["url"].string]))]
            case "simulator_inspect","simulator_tap","simulator_type","simulator_swipe","simulator_button":
                let result=try await service.input(device.id,bundle:bundle,action:action)
                if action.name=="simulator_inspect",self?.epoch==owner { self?.inspection=result["tree"].string };return result
            default:throw ACPError.workspace("Use Attach or Detach for device management.")
            }
        }
        operation=task
        defer { if epoch==owner { active=false;operation=nil;activity="" } }
        do {
            let result=try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation();guard epoch==owner,allowed,self.device?.id==device.id else { throw CancellationError() };return result
        } catch { if epoch==owner { self.error=error.localizedDescription };throw error }
    }
}
