import Foundation
import CCodeCore

struct NativeAccessRequest: Identifiable {
    let id=UUID()
    let chatID:UUID
    let generation:UUID
    let title:String
    let detail:String
}
extension AppStore {
    func resolveNativeAccess(_ id:UUID,allow:Bool) {
        guard let request=nativeAccessRequests.first(where:{ $0.id==id }),let continuation=nativeAccessDecisions.removeValue(forKey:id) else { return }
        nativeAccessRequests.removeAll { $0.id==id }
        if let chat=chat(request.chatID) { chat.sessionToolApprovalCount=max(0,chat.sessionToolApprovalCount-1) }
        continuation.resume(returning:allow)
    }
    func cancelNativeAccess(_ chat:ChatSession) {
        for request in nativeAccessRequests.filter({ $0.chatID==chat.id }) { resolveNativeAccess(request.id,allow:false) }
        chat.computerWorkspace.stop();chat.simulatorWorkspace.cancel();chat.simulatorWorkspace.allowed=false
    }
    private func validateNativeSource(_ chat:ChatSession,generation:UUID,computer:Bool) throws {
        guard chat.workspace.environment.isLocal,canDeliver(chat),!shuttingDown,!chat.closing,chat.state != .stopping,chat.connection != nil,chat.connectionGeneration==generation,(computer ? chat.transcript.computerToolsEnabled : chat.transcript.simulatorToolsEnabled)==true else { throw ACPError.workspace("Native tool access is disconnected or revoked.") }
    }
    private func decideNative(_ chat:ChatSession,generation:UUID,computer:Bool,title:String,detail:String) async throws {
        try validateNativeSource(chat,generation:generation,computer:computer);try Task.checkCancellation()
        guard nativeAccessRequests.count<16 else { throw ACPError.workspace("Finish pending native access requests first.") }
        let request=NativeAccessRequest(chatID:chat.id,generation:generation,title:title,detail:detail)
        let allowed=await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning:false);return }
                nativeAccessDecisions[request.id]=continuation;nativeAccessRequests.append(request);chat.sessionToolApprovalCount+=1
            }
        } onCancel: { Task { @MainActor [weak self] in self?.resolveNativeAccess(request.id,allow:false) } }
        try Task.checkCancellation();try validateNativeSource(chat,generation:generation,computer:computer)
        guard allowed else { throw ACPError.workspace("User declined native access.") }
    }
    func performNativeTool(_ chat:ChatSession,generation:UUID,name:String,arguments:JSONValue) async throws -> JSONValue {
        let computer=name.hasPrefix("computer_")
        try validateNativeSource(chat,generation:generation,computer:computer)
        setPane(computer ? "computer":"simulator",for:chat)
        if computer {
            let action=try ComputerAction(tool:name,arguments:arguments)
            if name != "computer_applications",chat.computerWorkspace.grants[action.appID]==nil {
                guard let app=chat.computerWorkspace.applications.first(where:{$0.id==action.appID}) else { throw ACPError.workspace("Open the requested app yourself first, then let the agent inspect it.") }
                try await decideNative(chat,generation:generation,computer:true,title:"Allow \(app.name) for this connection?",detail:"\(app.path)\nAccess: \(ComputerTier.forApp(app.id).rawValue). Screen contents can be shared with your agent. Access ends on Stop control or disconnect.")
                guard chat.computerWorkspace.applications.contains(app) else { throw ACPError.workspace("The requested app process changed while approval was pending.") };chat.computerWorkspace.allow(app.id)
            }
            let result=try await chat.computerWorkspace.perform(action);try validateNativeSource(chat,generation:generation,computer:true);return result
        }
        let action=try SimulatorAction(tool:name,arguments:arguments),sim=chat.simulatorWorkspace
        if name=="simulator_devices" { await sim.refreshDevices();try validateNativeSource(chat,generation:generation,computer:false);return ["devices":.array(sim.devices.map { ["device":.string($0.id),"name":.string($0.name),"runtime":.string($0.runtime),"state":.string($0.state)] }),"setup":.string(sim.error ?? "Ready")] }
        if name=="simulator_attach" {
            let id=arguments["device"].string.uppercased(),device=try await sim.service.validateDevice(id)
            try await decideNative(chat,generation:generation,computer:false,title:"Allow \(device.name) simulator?",detail:"\(device.runtime) · \(id)\nAllow screenshots and input on this simulated device for this agent connection.")
            try await attachSimulator(chat,id:id,agentGeneration:generation);return ["state":"attached","device":.string(id)]
        }
        if name=="simulator_detach" { await detachSimulator(chat);return ["state":"detached"] }
        guard let id=sim.device?.id,simulatorLeases[id]==chat.id else { throw ACPError.workspace("Attach a device to this chat first.") }
        if name=="simulator_build" || name=="simulator_open_url" {
            try await decideNative(chat,generation:generation,computer:false,title:name=="simulator_build" ? "Build this iOS project?":"Open this device URL?",detail:arguments.pretty)
            guard sim.device?.id==id,simulatorLeases[id]==chat.id else { throw ACPError.workspace("Device changed while approval was pending.") }
        }
        let result=try await sim.perform(action,workspace:chat.workspace);try validateNativeSource(chat,generation:generation,computer:false);return result
    }
    func attachSimulator(_ chat:ChatSession,id:String,agentGeneration:UUID?=nil) async throws {
        guard chat.workspace.environment.isLocal,!chat.simulatorWorkspace.active else { throw ACPError.workspace("Simulator attachment requires an idle local device pane.") }
        guard simulatorLeases[id]==nil || simulatorLeases[id]==chat.id else { throw ACPError.workspace("This simulator belongs to another chat. Detach it there or choose a different device.") }
        if chat.simulatorWorkspace.device?.id==id {
            if let generation=agentGeneration { try validateNativeSource(chat,generation:generation,computer:false);chat.simulatorWorkspace.allowed=true }
            return
        }
        await detachSimulator(chat)
        guard simulatorLeases[id]==nil,!shuttingDown,!chat.closing else { throw ACPError.workspace("Device is unavailable for attachment.") }
        simulatorLeases[id]=chat.id
        let sim=chat.simulatorWorkspace,owner=sim.epoch;sim.active=true;sim.activity="Attaching simulator"
        let task=Task { @MainActor in
            var attached=false
            defer { if !attached,simulatorLeases[id]==chat.id { simulatorLeases.removeValue(forKey:id) } }
            let booted=try await sim.service.boot(id)
            do {
                let device=try await sim.service.validateDevice(id)
                try Task.checkCancellation()
                guard sim.epoch==owner,!shuttingDown,!chat.closing else { throw CancellationError() }
                if let generation=agentGeneration { try validateNativeSource(chat,generation:generation,computer:false) }
                sim.device=device;sim.bootedByApp=booted;sim.allowed=agentGeneration != nil
                attached=true
                return booted
            } catch {
                if booted { _=try? await Task { try await sim.service.command(["shutdown",id]) }.value }
                throw error
            }
        };sim.bootTask=task
        defer { if sim.epoch==owner { sim.active=false;sim.activity="";sim.bootTask=nil } }
        do {
            _=try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch { if sim.epoch==owner { sim.error=error.localizedDescription };throw error }
    }
    func detachSimulator(_ chat:ChatSession) async {
        let sim=chat.simulatorWorkspace,id=sim.device?.id,owned=sim.bootedByApp
        sim.cancel();let boot=sim.bootTask;boot?.cancel();_=try? await boot?.value;sim.bootTask=nil
        sim.device=nil;sim.allowed=false;sim.bootedByApp=false;sim.image=nil;sim.inspection="";sim.bundle=""
        if let id,simulatorLeases[id]==chat.id { if owned { _=try? await sim.service.command(["shutdown",id]) };simulatorLeases.removeValue(forKey:id) }
    }
    func setNativeTools(_ chat:ChatSession,kind:String,enabled:Bool) async throws {
        guard ["computer","simulator"].contains(kind),chat.workspace.environment.isLocal,canDeliver(chat),!chat.busy,!chat.hasLiveAgentWork,chat.pendingPrompts.isEmpty,chat.pendingSettings.isEmpty else { throw ACPError.workspace("Finish work before changing native tools in a local chat.") }
        let reconnect=chat.connection != nil
        if enabled,reconnect,!chat.handshake["agentCapabilities"]["mcpCapabilities"]["http"].bool { throw ACPError.workspace("This agent does not advertise HTTP MCP native tools.") }
        chat.configuring=true;defer { chat.configuring=false }
        let old=kind=="computer" ? chat.transcript.computerToolsEnabled:chat.transcript.simulatorToolsEnabled
        if kind=="computer" { chat.transcript.computerToolsEnabled=enabled ? true:nil } else { chat.transcript.simulatorToolsEnabled=enabled ? true:nil }
        do { try await persistDelivery(chat) } catch { if kind=="computer" { chat.transcript.computerToolsEnabled=old } else { chat.transcript.simulatorToolsEnabled=old };throw error }
        if reconnect { await disconnect(chat);try await connect(chat) }
        else if !enabled { cancelNativeAccess(chat) }
    }
    func prepareNativeServer(_ chat:ChatSession,generation:UUID) async throws {
        guard chat.handshake["agentCapabilities"]["mcpCapabilities"]["http"].bool else { throw ACPError.workspace("Native control requires an agent with HTTP MCP support.") }
        let tools=(chat.transcript.computerToolsEnabled==true ? ComputerAction.tools:[]) + (chat.transcript.simulatorToolsEnabled==true ? SimulatorAction.tools:[])
        let server=BrowserToolServer(tools:tools,serverName:"ccode-native") { [weak self,weak chat] name,arguments in
            guard let self,let chat else { throw CancellationError() }
            do { let result=try await self.performNativeTool(chat,generation:generation,name:name,arguments:arguments);return result["content"].isNull ? ["content":[["type":"text","text":.string(result.pretty)]]]:result }
            catch is CancellationError { throw CancellationError() }
            catch { await self.reportNativeError(chat,computer:name.hasPrefix("computer_"),error:error.localizedDescription);return ["isError":true,"content":[["type":"text","text":.string(error.localizedDescription)]]] }
        }
        chat.nativeToolServer=server;chat.nativeToolGeneration=generation
        do { let endpoint=try await server.start();guard chat.connectionGeneration==generation,!chat.closing,!shuttingDown else { throw CancellationError() };chat.nativeToolEndpoint=endpoint }
        catch { await server.stop();if chat.nativeToolGeneration==generation { chat.nativeToolServer=nil;chat.nativeToolEndpoint=nil;chat.nativeToolGeneration=nil };throw error }
    }
    func reportNativeError(_ chat:ChatSession,computer:Bool,error:String) { if computer { chat.computerWorkspace.error=error } else { chat.simulatorWorkspace.error=error } }
    func stopNativeServer(_ chat:ChatSession,generation:UUID?=nil) async {
        guard generation==nil || chat.nativeToolGeneration==generation else { return }
        cancelNativeAccess(chat)
        let server=chat.nativeToolServer;chat.nativeToolServer=nil;chat.nativeToolEndpoint=nil;chat.nativeToolGeneration=nil;await server?.stop()
    }
}
