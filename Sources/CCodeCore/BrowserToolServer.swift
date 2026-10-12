import Foundation
import Network

public struct BrowserToolEndpoint: Sendable {
    public let url: URL
    public let token: String
}
public actor BrowserToolServer {
    private struct Connection {
        let socket: NWConnection
        var bytes = Data()
        var request: Task<Void, Never>?
        var timeout: Task<Void, Never>?
        var rpcID: JSONValue?
    }
    private let serverName: String
    private let tools: [JSONValue]
    private let handler: @Sendable (String, JSONValue) async throws -> JSONValue
    private let queue = DispatchQueue(label: "ccode.browser.mcp")
    private var listener: NWListener?
    private var endpoint: BrowserToolEndpoint?
    private var connections: [UUID: Connection] = [:]
    private var ready: CheckedContinuation<BrowserToolEndpoint, any Error>?
    private var stopping = false
    public init(tools: [JSONValue], serverName: String = "ccode-browser", handler: @escaping @Sendable (String, JSONValue) async throws -> JSONValue) {
        self.serverName=serverName; self.tools = tools; self.handler = handler
    }
    public func start() async throws -> BrowserToolEndpoint {
        try Task.checkCancellation()
        guard !stopping, listener == nil else { throw ACPError.workspace("Browser tools are already starting or running.") }
        let names = tools.map { $0["name"].string }
        guard !names.contains(""), Set(names).count == names.count,
              tools.allSatisfy({ $0["inputSchema"]["type"].string == "object" }) else { throw ACPError.workspace("Invalid browser tool catalog.") }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let socket = try NWListener(using: parameters)
        listener = socket
        socket.stateUpdateHandler = { [weak self, weak socket] state in
            Task { await self?.listenerState(state, socket: socket) }
        }
        socket.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection) } }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                ready = $0
                socket.start(queue: queue)
            }
        } onCancel: { Task { await self.stop() } }
    }
    public func stop() async {
        guard !stopping else { return }
        stopping = true
        let owned = Array(connections.values)
        connections.removeAll()
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil; endpoint = nil
        ready?.resume(throwing: CancellationError()); ready = nil
        for connection in owned { connection.request?.cancel(); connection.timeout?.cancel(); connection.socket.cancel() }
        for connection in owned { await connection.request?.value; await connection.timeout?.value }
        stopping = false
    }
    private func listenerState(_ state: NWListener.State, socket: NWListener?) {
        guard let socket, listener === socket else { return }
        switch state {
        case .ready:
            guard let port = socket.port, let url = URL(string: "http://127.0.0.1:\(port.rawValue)/mcp") else { return }
            let value = BrowserToolEndpoint(url: url, token: UUID().uuidString + UUID().uuidString)
            endpoint = value; ready?.resume(returning: value); ready = nil
        case .failed(let error):
            ready?.resume(throwing: error); ready = nil; socket.cancel(); listener = nil; endpoint = nil
        case .cancelled:
            ready?.resume(throwing: CancellationError()); ready = nil
        default: break
        }
    }
    private func accept(_ socket: NWConnection) {
        guard !stopping, endpoint != nil, connections.count < 16 else { socket.cancel(); return }
        let id = UUID()
        connections[id] = Connection(socket: socket)
        connections[id]?.timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)); await self?.close(id) } catch {}
        }
        socket.start(queue: queue)
        receive(id)
    }
    private func receive(_ id: UUID) {
        connections[id]?.socket.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { await self?.received(id, data: data, complete: complete, failed: error != nil) }
        }
    }
    private func received(_ id: UUID, data: Data?, complete: Bool, failed: Bool) {
        guard var connection = connections[id], connection.request == nil else { return }
        if let data { connection.bytes.append(data) }
        connections[id] = connection
        guard connection.bytes.count <= 264 * 1024 else { respond(id, status: 413); return }
        guard let boundary = connection.bytes.range(of: Data("\r\n\r\n".utf8)) else {
            if connection.bytes.count > 8192 { respond(id, status: 431) }
            else if complete || failed { close(id) }
            else { receive(id) }
            return
        }
        guard boundary.lowerBound <= 8192, let header = String(data: connection.bytes[..<boundary.lowerBound], encoding: .utf8) else { respond(id, status: 400); return }
        let lines = header.components(separatedBy: "\r\n"), first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3, first[1] == "/mcp", first[2] == "HTTP/1.1" else { respond(id, status: 400); return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { respond(id, status: 400); return }
            let key = line[..<colon].lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard headers[key] == nil else { respond(id, status: 400); return }
            headers[key] = value
        }
        guard let endpoint else { close(id); return }
        guard headers["authorization"] == "Bearer " + endpoint.token else { respond(id, status: 401); return }
        let authority = "127.0.0.1:\(endpoint.url.port!)"
        guard headers["host"] == authority, headers["origin"] == nil || headers["origin"] == "http://" + authority else { respond(id, status: 403); return }
        guard first[0] == "POST" else { respond(id, status: 405); return }
        guard headers["transfer-encoding"] == nil,
              headers["content-type"]?.split(separator: ";").first?.lowercased() == "application/json",
              let rawLength = headers["content-length"], !rawLength.isEmpty, rawLength.allSatisfy(\.isNumber),
              let length = Int(rawLength), length <= 256 * 1024,
              ["2025-06-18", "2025-03-26"].contains(headers["mcp-protocol-version"] ?? "2025-03-26") else { respond(id, status: 400); return }
        let total = boundary.upperBound + length
        if connection.bytes.count < total {
            if complete || failed { respond(id, status: 400) } else { receive(id) }
            return
        }
        guard connection.bytes.count == total else { respond(id, status: 400); return }
        let bytes = Data(connection.bytes[boundary.upperBound..<total])
        guard let body = try? JSONDecoder().decode(JSONValue.self, from: bytes) else { respond(id, status: 200, body: rpcError(.null, code: -32700, message: "Invalid JSON.")); return }
        connections[id]?.bytes = Data()
        connections[id]?.timeout?.cancel()
        connections[id]?.timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(300)); await self?.close(id) } catch {}
        }
        connections[id]?.rpcID = body["id"]
        connections[id]?.request = Task { [weak self] in await self?.dispatch(id, body: body) }
    }
    private func dispatch(_ id: UUID, body: JSONValue) async {
        let rpcID = body["id"], method = body["method"].string, params = body["params"]
        guard case .object = body, body["jsonrpc"].string == "2.0", !method.isEmpty,
              rpcID.isNull || rpcID.optionalString != nil || rpcID.exactInteger != nil else {
            respond(id, status: 200, body: rpcError(.null, code: -32600, message: "Invalid request.")); return
        }
        if rpcID.isNull {
            if method == "notifications/cancelled" {
                let target = params["requestId"]
                for (other, connection) in connections where other != id && connection.rpcID == target && !target.isNull { connection.request?.cancel() }
            }
            respond(id, status: 202); return
        }
        guard !connections.contains(where: { $0.key != id && $0.value.rpcID == rpcID }) else {
            respond(id, status: 200, body: rpcError(rpcID, code: -32600, message: "Duplicate request ID.")); return
        }
        var result: JSONValue
        switch method {
        case "initialize":
            let requested = params["protocolVersion"].string
            result = ["protocolVersion": .string(requested == "2025-03-26" ? requested : "2025-06-18"), "capabilities": ["tools": ["listChanged": false]], "serverInfo": ["name": .string(serverName), "version": "1"]]
        case "ping": result = [:]
        case "tools/list": result = ["tools": .array(tools)]
        case "tools/call":
            let name = params["name"].string
            guard tools.contains(where: { $0["name"].string == name }), case .object = params["arguments"] else {
                respond(id, status: 200, body: rpcError(rpcID, code: -32602, message: "Unknown tool or invalid arguments.")); return
            }
            do { result = try await handler(name, params["arguments"]); try Task.checkCancellation() }
            catch is CancellationError { close(id); return }
            catch { result = ["isError": true, "content": [["type": "text", "text": "Browser operation failed. Check the browser pane for details."]]] }
        default:
            respond(id, status: 200, body: rpcError(rpcID, code: -32601, message: "Method not found.")); return
        }
        respond(id, status: 200, body: ["jsonrpc": "2.0", "id": rpcID, "result": result])
    }
    private func rpcError(_ id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }
    private func respond(_ id: UUID, status: Int, body: JSONValue? = nil) {
        guard let connection = connections[id] else { return }
        let bytes = body.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        guard bytes.count <= 3 * 1024 * 1024 else {
            respond(id, status: 413); return
        }
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 405: "Method Not Allowed", 413: "Content Too Large", 431: "Request Header Fields Too Large"][status] ?? "Error"
        var response = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8)
        response.append(bytes)
        connection.socket.send(content: response, completion: .contentProcessed { [weak self] _ in Task { await self?.close(id) } })
    }
    private func close(_ id: UUID) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.timeout?.cancel(); connection.request?.cancel(); connection.socket.cancel()
    }
}
