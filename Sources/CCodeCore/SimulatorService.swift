import Foundation

public struct NativeCommandRunner: Sendable {
    public init() {}
    public func run(_ executable:String,_ arguments:[String],directory:String="/",environment:[String:String]?=nil,timeout:Duration = .seconds(60),limit:Int=1024*1024) async throws -> String {
        let terminals=TerminalService()
        do {
            let id=try await terminals.create(command:executable,arguments:arguments,directory:directory,environment:environment ?? [:],byteLimit:limit,captureStandardErrorSeparately:true)
            let status=try await withThrowingTaskGroup(of:JSONValue.self) { group in
                group.addTask { try await terminals.wait(id) };group.addTask { try await Task.sleep(for:timeout);throw ACPError.workspace("Native tool timed out. Inspect the device before retrying changes.") };defer { group.cancelAll() };return try await group.next()!
            }
            let output=try await terminals.output(id);await terminals.close()
            guard !output["truncated"].bool else { throw ACPError.workspace("Native tool output exceeded its limit.") }
            guard status["exitCode"].exactInteger==0,status["signal"].isNull else { throw ACPError.workspace(String(output["standardError"].string.suffix(2500))+String(output["output"].string.suffix(2500))) }
            return output["output"].string
        } catch { await terminals.close();throw error }
    }
}
public struct SimulatorService: Sendable {
    public let xcrun:String
    public let cache:URL
    public let helper:URL
    public init(cache:URL,helper:URL,xcrun:String="/usr/bin/xcrun") { self.cache=cache;self.helper=helper;self.xcrun=xcrun }
    public func devices() async throws -> [SimulatorDevice] {
        let output=try await command(["list","devices","available","--json"])
        return SimulatorDevice.parse(try JSONDecoder().decode(JSONValue.self,from:Data(output.utf8)))
    }
    public func command(_ arguments:[String],timeout:Duration = .seconds(60)) async throws -> String { try await NativeCommandRunner().run(xcrun,["simctl"]+arguments,timeout:timeout) }
    public func validateDevice(_ id:String) async throws -> SimulatorDevice {
        guard UUID(uuidString:id) != nil,let device=try await devices().first(where:{ $0.id.caseInsensitiveCompare(id) == .orderedSame }) else { throw ACPError.workspace("This iOS simulator is unavailable. Install an iOS runtime in Xcode → Settings → Components.") };return device
    }
    public func boot(_ id:String) async throws -> Bool {
        let device=try await validateDevice(id)
        if device.booted { return false }
        _=try await command(["boot",device.id])
        do { _=try await command(["bootstatus",device.id,"-b"],timeout:.seconds(180));return true }
        catch {
            // Boot succeeded on a previously shut-down device. Cleanup is an
            // independently owned task so cancellation cannot skip it.
            _=try? await Task { try await command(["shutdown",device.id]) }.value
            throw error
        }
    }
    public func screenshot(_ id:String) async throws -> Data {
        _=try await validateDevice(id);try Task.checkCancellation()
        let folder=cache.appendingPathComponent("capture-"+UUID().uuidString);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);defer { try? FileManager.default.removeItem(at:folder) }
        let file=folder.appendingPathComponent("screen.jpeg")
        _=try await command(["io",id,"screenshot","--type=jpeg",file.path])
        let values=try file.resourceValues(forKeys:[.fileSizeKey]);guard let size=values.fileSize,size>0,size<=2*1024*1024 else { throw ACPError.workspace("Simulator screenshot exceeds 2 MiB.") };return try Data(contentsOf:file)
    }
    public func install(_ id:String,app:String,workspace:Workspace) async throws -> String {
        guard workspace.environment.isLocal else { throw ACPError.workspace("Simulator installation requires a local workspace.") }
        let scoped=try await workspace.scoped(app).path
        guard scoped.hasSuffix(".app"),FileManager.default.fileExists(atPath:scoped+"/Info.plist") else { throw ACPError.workspace("Choose a built simulator .app inside this workspace.") }
        _=try await validateDevice(id);return try await command(["install",id,scoped])
    }
    public func build(_ id:String,project:String,scheme:String,workspace:Workspace) async throws -> String {
        _=try SimulatorAction(tool:"simulator_build",arguments:["project":.string(project),"scheme":.string(scheme)])
        guard workspace.environment.isLocal else { throw ACPError.workspace("Simulator builds require a local workspace.") }
        let path=try await workspace.scoped(workspace.filePath(project)).path;_=try await validateDevice(id)
        // Outputs remain in this workspace so install can use the same scoped path.
        let output=try await workspace.scoped(workspace.filePath(".ccode/simulator-build/"+id)).path
        return try await NativeCommandRunner().run("/usr/bin/xcodebuild",[path.hasSuffix(".xcworkspace") ? "-workspace":"-project",path,"-scheme",scheme,"-destination","platform=iOS Simulator,id="+id,"-derivedDataPath",output,"CODE_SIGNING_ALLOWED=NO","build"],directory:workspace.root,timeout:.seconds(600),limit:2*1024*1024)
    }
    public func input(_ id:String,bundle:String,action:SimulatorAction) async throws -> JSONValue {
        _=try await validateDevice(id)
        guard !bundle.isEmpty,bundle.count<=256,bundle.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-".contains($0)) }) else { throw ACPError.workspace("Launch an app before inspecting or controlling it.") }
        guard FileManager.default.fileExists(atPath:helper.path) else { throw ACPError.workspace("The packaged XCTest simulator helper is missing.") }
        let payload:JSONValue=["action":.string(action.name),"bundle":.string(bundle),"arguments":action.arguments]
        let output=try await NativeCommandRunner().run("/usr/bin/python3",[helper.path,cache.path,id,payload.pretty],timeout:.seconds(240),limit:2*1024*1024)
        guard let line=output.split(separator:"\n").last(where:{$0.hasPrefix("CCODE_SIM_RESULT=")}),let data=Data(base64Encoded:String(line.dropFirst("CCODE_SIM_RESULT=".count))) else { throw ACPError.workspace("XCTest did not return a verified device result. Inspect before retrying input.") }
        return try JSONDecoder().decode(JSONValue.self,from:data)
    }
}
