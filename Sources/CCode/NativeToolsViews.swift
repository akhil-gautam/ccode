import SwiftUI
import AppKit
import ApplicationServices
import CCodeCore

struct NativeAccessRequestsView: View {
    let chat:ChatSession
    @Bindable var store:AppStore
    var body:some View {
        if let request=store.nativeAccessRequests.first(where:{$0.chatID==chat.id}) {
            VStack(alignment:.leading,spacing:10) {
                Label(request.title,systemImage:"hand.raised").fontWeight(.medium)
                ScrollView { Text(request.detail).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }.frame(maxHeight:140)
                HStack { Button("Decline") { store.resolveNativeAccess(request.id,allow:false) };Spacer();Button("Allow") { store.resolveNativeAccess(request.id,allow:true) } }
            }.font(.system(size:13)).padding(12).background(Palette.muted,in:RoundedRectangle(cornerRadius:10)).padding(.horizontal,26)
        }
    }
}
struct NativePermissionsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var readiness=MacComputerEngine().readiness
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack { Text("Computer & simulator access").font(.title2);Spacer();Button("Done") { dismiss() } }
            Text("Computer control is enabled for each chat from its Computer pane. Apps require separate consent; screenshots are shared only with that chat’s agent.").foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            permission("Accessibility",ready:readiness.accessibility,url:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            permission("Screen Recording",ready:readiness.screenRecording,url:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            Button("Request macOS computer permissions") {
                _=AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt":true] as CFDictionary)
                _=CGRequestScreenCaptureAccess();readiness=MacComputerEngine().readiness
            }
            Divider()
            Text("Simulator workflows use Xcode and an installed iOS runtime. They don’t require desktop screen-control permissions. Choose a device in the Simulator pane and allow the agent to use it.").foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Button("Refresh permission status") { readiness=MacComputerEngine().readiness }
        }.padding(26).frame(width:560)
    }
    private func permission(_ title:String,ready:Bool,url:String) -> some View {
        HStack { Label(title,systemImage:ready ? "checkmark.circle":"exclamationmark.circle");Spacer();Text(ready ? "Ready":"Required").foregroundStyle(ready ? Color.green:.orange);Button("Open System Settings") { if let link=URL(string:url) { NSWorkspace.shared.open(link) } } }
    }
}
struct ComputerPane: View {
    @Bindable var chat:ChatSession
    @Bindable var store:AppStore
    @State private var apps:[ComputerApplication]=[]
    @State private var showPermissions=false
    private var computer:ComputerWorkspace { chat.computerWorkspace }
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Toggle("Agent computer control",isOn:Binding(get:{chat.transcript.computerToolsEnabled==true},set:{enabled in Task { do { try await store.setNativeTools(chat,kind:"computer",enabled:enabled) } catch { computer.error=error.localizedDescription } } })).disabled(!chat.workspace.environment.isLocal || chat.busy || chat.hasLiveAgentWork)
                Spacer();Button("Stop control") { store.cancelNativeAccess(chat);store.stop(chat) }.disabled(computer.grants.isEmpty && !computer.active)
            }
            Text(computer.readiness.ready ? "Accessibility and Screen Recording ready":"macOS computer permissions required").font(.caption).foregroundStyle(computer.readiness.ready ? Color.green:.orange)
            Button("Computer permissions…") { showPermissions=true }
            if computer.active { HStack { ProgressView().controlSize(.small);Text("Agent is controlling \(computer.activity)") }.foregroundStyle(Palette.accent) }
            if let error=computer.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack { Text("Apps for this connection").font(.headline);Spacer();Button("Refresh") { apps=computer.applications } }
            ScrollView {
                LazyVStack(alignment:.leading,spacing:14) { ForEach(apps) { app in
                    VStack(alignment:.leading,spacing:5) {
                        HStack { Text(app.name).lineLimit(1);Spacer();Button(computer.grants[app.id] == app ? "Revoke":"Allow") { if computer.grants[app.id] == app { computer.revoke(app.id) } else { computer.allow(app.id) } }.disabled(chat.transcript.computerToolsEnabled != true || !computer.readiness.ready) }
                        Text(ComputerTier.forApp(app.id) == .view ? "View only":ComputerTier.forApp(app.id) == .click ? "Click and scroll only":"Full control").font(.caption).foregroundStyle(.secondary)
                        Text(app.id).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                    }.padding(10).background(Palette.muted,in:RoundedRectangle(cornerRadius:8))
                } }
            }
            Text("Access ends on Stop control or disconnect. Browsers use dedicated browser tools; terminals and IDEs use workspace commands for typing.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }.padding(16).onAppear { apps=computer.applications }.sheet(isPresented:$showPermissions) { NativePermissionsView() }
    }
}
struct SimulatorPane: View {
    @Bindable var chat:ChatSession
    @Bindable var store:AppStore
    @State private var chosen=""
    private var sim:SimulatorWorkspace { chat.simulatorWorkspace }
    var body:some View {
        VStack(spacing:12) {
            HStack {
                Toggle("Agent simulator tools",isOn:Binding(get:{chat.transcript.simulatorToolsEnabled==true},set:{enabled in Task { do { try await store.setNativeTools(chat,kind:"simulator",enabled:enabled) } catch { sim.error=error.localizedDescription } } })).disabled(!chat.workspace.environment.isLocal || chat.busy || chat.hasLiveAgentWork || sim.active)
                Spacer();Button("Stop") { sim.cancel();store.stop(chat) }.disabled(!sim.active)
            }
            HStack {
                Picker("Device",selection:$chosen) { Text("Choose simulator").tag("");ForEach(sim.devices) { Text($0.name+" · "+$0.runtime.components(separatedBy:".").last!+" · "+$0.state).tag($0.id) } }.labelsHidden()
                Button("Refresh") { Task { await sim.refreshDevices() } }
            }.disabled(sim.active)
            if sim.device==nil {
                Button("Attach simulator") { Task { do { try await store.attachSimulator(chat,id:chosen) } catch { sim.error=error.localizedDescription } } }.disabled(chosen.isEmpty || sim.active || !chat.workspace.environment.isLocal)
            } else {
                HStack { Text(sim.device?.name ?? "").font(.headline);Spacer();Button("Detach") { Task { await store.detachSimulator(chat) } }.disabled(sim.active) }
                Toggle("Let agent use this device",isOn:Binding(get:{sim.allowed},set:{sim.allowed=$0;if !$0 { sim.cancel() }})).disabled(chat.transcript.simulatorToolsEnabled != true)
                HStack { TextField("App bundle identifier",text:Binding(get:{sim.bundle},set:{sim.bundle=$0})).textFieldStyle(.roundedBorder);Button("Launch") { invoke("simulator_launch",["bundle":.string(sim.bundle)]) }.disabled(sim.bundle.isEmpty || !sim.allowed || sim.active) }
                HStack { Button("Screenshot") { Task { do { _=try await sim.capture() } catch { sim.error=error.localizedDescription } } };Button("Inspect") { invoke("simulator_inspect",[:]) };Button("Home") { invoke("simulator_button",["button":"home"]) };Button("Rotate") { invoke("simulator_button",["button":"rotate"]) } }.disabled(sim.active || !sim.allowed)
            }
            if sim.active { HStack { ProgressView().controlSize(.small);Text("Agent is using this device · \(sim.activity)") }.font(.caption) }
            if let error=sim.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal:false,vertical:true) }
            if let data=sim.image,let image=NSImage(data:data) {
                GeometryReader { geometry in
                    let ratio=image.size.width/max(1,image.size.height),height=min(geometry.size.height,geometry.size.width/ratio),width=height*ratio
                    Image(nsImage:image).resizable().frame(width:width,height:height).background(Color.black).clipShape(RoundedRectangle(cornerRadius:12)).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance:0).onEnded { value in
                            guard sim.allowed,!sim.active else { return }
                            let a=value.startLocation,b=value.location
                            let args:JSONValue=["x":.number(min(1,max(0,a.x/width))),"y":.number(min(1,max(0,a.y/height))),"to_x":.number(min(1,max(0,b.x/width))),"to_y":.number(min(1,max(0,b.y/height)))]
                            invoke(hypot(a.x-b.x,a.y-b.y)<6 ? "simulator_tap":"simulator_swipe",args)
                        }).frame(maxWidth:.infinity,maxHeight:.infinity)
                }.frame(minHeight:160)
            } else { ContentUnavailableView("iOS Simulator",systemImage:"iphone",description:Text("Attach a device to inspect and test your app.")) }
            if !sim.inspection.isEmpty { DisclosureGroup("Screen inspection") { ScrollView { Text(sim.inspection).font(.caption.monospaced()).textSelection(.enabled) }.frame(maxHeight:120) } }
        }.padding(14).task { await sim.refreshDevices() }
        .task(id:sim.device?.id) {
            while !Task.isCancelled,sim.device != nil {
                if !sim.active { _=try? await sim.capture() }
                do { try await Task.sleep(for:.seconds(2)) } catch { return }
            }
        }
    }
    private func invoke(_ name:String,_ arguments:JSONValue) { Task { do { _=try await sim.perform(try SimulatorAction(tool:name,arguments:arguments),workspace:chat.workspace) } catch { sim.error=error.localizedDescription } } }
}
