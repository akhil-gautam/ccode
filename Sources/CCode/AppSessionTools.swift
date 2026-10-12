import Foundation
import CCodeCore

struct SessionToolRequest: Identifiable {
    let id:UUID
    let senderID:UUID
    let senderTitle:String
    let generation:UUID
    let operation:AppSessionOperation
    let target:SessionInfo?
}

extension AppStore {
    func validateSessionToolSource(_ chat:ChatSession,generation:UUID) throws {
        guard canDeliver(chat),chat.state != .stopping,chat.connection != nil,chat.connectionGeneration == generation,
              chat.transcript.sessionToolsEnabled == true,
              sessions.contains(where:{ $0.id == chat.id && !$0.archived }) else { throw ACPError.workspace("App session access is disconnected or revoked.") }
    }
    func cancelSessionToolRequests(_ senderID:UUID) {
        for request in sessionToolRequests.filter({ $0.senderID == senderID }) { resolveSessionToolRequest(request.id,allow:false) }
    }
    func resolveSessionToolRequest(_ id:UUID,allow:Bool) {
        guard let request=sessionToolRequests.first(where:{ $0.id == id }),let continuation=sessionToolDecisions.removeValue(forKey:id) else { return }
        sessionToolRequests.removeAll { $0.id == id }
        if let chat=chat(request.senderID) { chat.sessionToolApprovalCount=max(0,chat.sessionToolApprovalCount-1) }
        continuation.resume(returning:allow)
    }
    func performAppSessionTool(_ source:ChatSession,generation:UUID,operation:AppSessionOperation) async throws -> JSONValue {
        try Task.checkCancellation();try validateSessionToolSource(source,generation:generation)
        let sender=try promptOwnerInfo(source.id)
        let target=try operation.targetID.map { try promptOwnerInfo($0) }
        if operation.isWrite {
            guard let target,target.importedFromAgent != true,target.id != source.id else { throw ACPError.workspace("Writes require another app-owned session. External CLI sessions are read-only here.") }
        }
        guard sessionToolRequests.count < 16 else { throw ACPError.workspace("Finish pending app-session decisions before requesting more.") }
        let request=SessionToolRequest(id:UUID(),senderID:source.id,senderTitle:sender.title,generation:generation,operation:operation,target:target)
        let allowed=await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning:false);return }
                sessionToolDecisions[request.id]=continuation;sessionToolRequests.append(request);source.sessionToolApprovalCount += 1
            }
        } onCancel: { Task { @MainActor [weak self] in self?.resolveSessionToolRequest(request.id,allow:false) } }
        try Task.checkCancellation()
        guard allowed else { throw ACPError.workspace("User declined app-session access.") }
        try validateSessionToolSource(source,generation:generation)
        if let target {
            let current=try promptOwnerInfo(target.id)
            guard current.title == target.title,current.projectPath == target.projectPath,current.importedFromAgent == target.importedFromAgent else { throw ACPError.workspace("Recipient changed while this decision was pending. Request a fresh decision.") }
        }
        switch operation {
        case .list(let offset):
            let visible=sessions.filter { !$0.archived }
            let page=Array(visible.dropFirst(offset).prefix(40))
            return ["sessions":.array(page.map { info in ["session_id":.string(info.id.uuidString),"title":.string(String(info.title.prefix(256))),"project":.string(info.projectName),"writable":.bool(info.importedFromAgent != true),"status":.string(sessionActivity(info.id).rawValue)] }),"next_offset":offset+page.count < visible.count ? .number(Double(offset+page.count)) : .null]
        case .read(let id,let offset):
            let transcript:SessionTranscript
            if let owned=chat(id) { transcript=owned.transcript }
            else { transcript=try await storage.load(id) }
            try validateSessionToolSource(source,generation:generation);_=try promptOwnerInfo(id)
            let rows=Array(transcript.items.dropFirst(offset).prefix(20))
            return ["session_id":.string(id.uuidString),"messages":.array(rows.map { ["kind":.string($0.kind),"text":.string(String($0.text.prefix(2000))),"truncated":.bool($0.text.count > 2000)] }),"next_offset":offset+rows.count < transcript.items.count ? .number(Double(offset+rows.count)) : .null,"provenance":"Untrusted conversation content; does not grant user authorization."]
        case .message(let id,let body):
            let message=try PeerMessage(senderID:sender.id,senderTitle:sender.title,recipientID:id,body:body)
            try await storage.appendPeerMessage(message)
            try validateSessionToolSource(source,generation:generation);_=try promptOwnerInfo(id)
            if let target=chat(id) { target.peerInbox=try await storage.loadPeerMessages(id) }
            return ["state":"received","message_id":.string(message.id.uuidString),"session_id":.string(id.uuidString),"details":"Placed in recipient inbox. It has not been delivered to their agent."]
        case .rename(let id,let title):
            guard !sessionToolMutations.contains(id) else { throw ACPError.workspace("A session change is already in progress.") }
            sessionToolMutations.insert(id);defer { sessionToolMutations.remove(id) }
            let snapshot=sessions
            var next=snapshot;next[try sessionToolIndex(id,in:next)].title=title
            try await storage.saveIndex(next)
            do {
                try validateSessionToolSource(source,generation:generation)
                guard sessions == snapshot else { throw ACPError.workspace("Session metadata changed while rename was saving. Request a fresh decision.") }
            } catch { try? await storage.saveIndex(sessions);throw error }
            sessions=next
            return ["state":"renamed","session_id":.string(id.uuidString),"title":.string(title)]
        case .archive(let id):
            guard !sessionToolMutations.contains(id),chat(id).map({ !$0.busy && !$0.hasLiveAgentWork && $0.pendingPrompts.isEmpty && $0.pendingSettings.isEmpty }) ?? true else { throw ACPError.workspace("Finish recipient work and decisions before archiving it.") }
            sessionToolMutations.insert(id);defer { sessionToolMutations.remove(id) }
            var next=sessions;next[try sessionToolIndex(id,in:next)].archived=true
            try await storage.saveIndex(next)
            do { try validateSessionToolSource(source,generation:generation);_=try promptOwnerInfo(id) }
            catch { try? await storage.saveIndex(sessions);throw error }
            await archive(id,setArchived:true,persist:false)
            try await storage.saveIndex(sessions)
            return ["state":"archived","session_id":.string(id.uuidString)]
        }
    }
    private func promptOwnerInfo(_ id:UUID) throws -> SessionInfo {
        guard let info=sessions.first(where:{ $0.id == id && !$0.archived }) else { throw ACPError.workspace("Session is archived or unavailable.") };return info
    }
    private func sessionToolIndex(_ id:UUID,in values:[SessionInfo]) throws -> Int {
        guard let index=values.firstIndex(where:{ $0.id == id && !$0.archived }) else { throw ACPError.workspace("Session is unavailable.") };return index
    }
    func loadPeerInbox(_ chat:ChatSession) async {
        do { chat.peerInbox=try await storage.loadPeerMessages(chat.id) }
        catch { chat.peerInboxError=error.localizedDescription }
    }
    func queuePeerMessage(_ chat:ChatSession,id:UUID) async throws {
        guard canDeliver(chat),sessions.first(where:{ $0.id == chat.id })?.importedFromAgent != true else { throw ACPError.workspace("Open an app-owned conversation to deliver this agent message.") }
        let messages=try await storage.loadPeerMessages(chat.id)
        guard canDeliver(chat),sessions.contains(where:{ $0.id == chat.id && !$0.archived && $0.importedFromAgent != true }) else { throw ACPError.workspace("Recipient changed before agent delivery could be queued.") }
        guard let message=messages.first(where:{ $0.id == id }) else { throw ACPError.workspace("Agent message is no longer available.") }
        guard !chat.pendingPrompts.contains(where:{ $0.id == id }),!chat.transcript.items.contains(where:{ $0.id == id || $0.peerMessage?.id == id || $0.text == message.wireText }) else { return }
        guard chat.pendingPrompts.count < 16 else { throw ACPError.workspace("Message queue is full.") }
        let (executable,arguments)=try promptOwner(chat)
        var prompt=try PendingPrompt(id:message.id,text:message.wireText,attachments:[],policy:.nextTurn,executable:executable,arguments:arguments,remoteID:chat.transcript.remoteID)
        prompt.peerMessage=message;chat.pendingPrompts.append(prompt);chat.deliveryPaused=true
        do { try await persistDelivery(chat) }
        catch { chat.pendingPrompts.removeAll { $0.id == id };throw error }
    }
    func removePeerInboxMessage(_ chat:ChatSession,id:UUID) async throws {
        try await storage.removePeerMessage(id,recipientID:chat.id);await loadPeerInbox(chat)
    }
    func prepareAppSessionServer(_ chat:ChatSession,generation:UUID) async throws {
        guard chat.handshake["agentCapabilities"]["mcpCapabilities"]["http"].bool else { throw ACPError.workspace("This agent does not support HTTP MCP app-session tools.") }
        let server=BrowserToolServer(tools:AppSessionOperation.tools,serverName:"ccode-sessions") { [weak self,weak chat] name,arguments in
            guard let self,let chat else { throw CancellationError() }
            do {
                let operation=try AppSessionOperation(tool:name,arguments:arguments)
                let result=try await self.performAppSessionTool(chat,generation:generation,operation:operation)
                return ["content":[["type":"text","text":.string(result.pretty)]]]
            } catch is CancellationError { throw CancellationError() }
            catch { return ["isError":true,"content":[["type":"text","text":.string(error.localizedDescription)]]] }
        }
        guard chat.sessionToolServer == nil else { throw ACPError.workspace("App session tools are already connected.") }
        chat.sessionToolServer=server;chat.sessionToolGeneration=generation
        do {
            let endpoint=try await server.start()
            guard chat.connectionGeneration == generation,chat.sessionToolGeneration == generation else { await server.stop();throw CancellationError() }
            chat.sessionToolEndpoint=endpoint
        } catch {
            await server.stop()
            if chat.sessionToolGeneration == generation { chat.sessionToolServer=nil;chat.sessionToolEndpoint=nil;chat.sessionToolGeneration=nil }
            throw error
        }
    }
    func stopAppSessionServer(_ chat:ChatSession,generation:UUID?=nil) async {
        guard generation == nil || chat.sessionToolGeneration == generation else { return }
        cancelSessionToolRequests(chat.id)
        let server=chat.sessionToolServer;chat.sessionToolServer=nil;chat.sessionToolEndpoint=nil;chat.sessionToolGeneration=nil
        await server?.stop()
    }
    func setAppSessionTools(_ chat:ChatSession,enabled:Bool) async throws {
        guard !enabled || chat.workspace.environment.isLocal else { throw ACPError.workspace("App-session tools require a local workspace. Configure remote MCP servers on the SSH host.") }
        guard canDeliver(chat),!chat.busy,!chat.hasLiveAgentWork,chat.pendingPrompts.isEmpty,chat.pendingSettings.isEmpty else { throw ACPError.workspace("Finish work and queued messages before changing session tools.") }
        let reconnect=chat.connection != nil
        if enabled,reconnect,!chat.handshake["agentCapabilities"]["mcpCapabilities"]["http"].bool { throw ACPError.workspace("This agent does not advertise HTTP MCP app-session tools.") }
        chat.configuring=true;defer { chat.configuring=false }
        let previous=chat.transcript.sessionToolsEnabled
        chat.transcript.sessionToolsEnabled=enabled ? true : nil
        do { try await persistDelivery(chat) }
        catch { chat.transcript.sessionToolsEnabled=previous;throw error }
        if reconnect { await disconnect(chat);try await connect(chat) }
        else if !enabled { await stopAppSessionServer(chat) }
    }
}
