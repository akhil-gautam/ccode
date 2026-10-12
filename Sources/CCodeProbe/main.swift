import Foundation
import CCodeCore

@main struct Probe {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let executable = arguments.first else { print("Usage: ccode-probe /absolute/agent [arguments...]"); exit(2) }
        let peer = ACPConnection(onUpdates: { _ in }, onRequest: { method, _ in throw ACPError.methodNotFound(method) })
        do {
            try await peer.start(executable: executable, arguments: Array(arguments.dropFirst()), directory: FileManager.default.currentDirectoryPath)
            let result = try await peer.request("initialize", params: ["protocolVersion": 1, "clientCapabilities": [:], "clientInfo": ["name": "ccode-probe", "version": "0.1.0"]], timeout: .seconds(20))
            guard result["protocolVersion"].int == 1 else { throw ACPError.protocolViolation("Unsupported protocol version.") }
            print("ACP \(result["protocolVersion"].int): \(result["agentInfo"]["name"].string) \(result["agentInfo"]["version"].string)")
            print("Capabilities: \(result["agentCapabilities"].object.keys.sorted().joined(separator: ", "))")
            let session = try await peer.request("session/new", params: ["cwd": .string(FileManager.default.currentDirectoryPath), "mcpServers": []], timeout: .seconds(20))
            print("Session created: \(!session["sessionId"].string.isEmpty); config options: \(session["configOptions"].array.count)")
            await peer.close()
        } catch { await peer.close(); fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
}
