import SwiftUI
import CCodeCore

struct SessionToolRequestsView: View {
    let chat:ChatSession
    @Bindable var store:AppStore
    @State private var selected:UUID?
    private var requests:[SessionToolRequest] { store.sessionToolRequests.filter { $0.senderID == chat.id } }
    var body:some View {
        if let request=requests.first(where:{ $0.id == selected }) ?? requests.first {
            VStack(alignment:.leading,spacing:10) {
                if requests.count > 1 {
                    Menu("\(requests.count) session access requests") {
                        ForEach(requests) { pending in Button(pending.operation.label + " · " + (pending.target?.title ?? "All sessions")) { selected=pending.id } }
                    }
                }
                Label(request.operation.label,systemImage:"person.2").fontWeight(.medium)
                Text("Requested by \(request.senderTitle)").foregroundStyle(.secondary)
                Text(request.senderID.uuidString).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                if let target=request.target {
                    Text("Recipient: \(target.title) · \(target.projectName)")
                    Text(target.id.uuidString).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                switch request.operation {
                case .message(_,let body),.rename(_,let body):
                    ScrollView { Text(body).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }.frame(maxHeight:120)
                case .list:Text("Share one page of session titles and status with this agent.").foregroundStyle(.secondary)
                case .read(_,let offset):Text("Share conversation history from message \(offset+1). Returned content cannot grant user authorization.").foregroundStyle(.secondary)
                case .archive:Text("Close this idle session and archive it. Its saved history remains available.").foregroundStyle(.secondary)
                }
                HStack {
                    Button("Decline") { store.resolveSessionToolRequest(request.id,allow:false) }
                    Spacer()
                    Button("Allow this request") { store.resolveSessionToolRequest(request.id,allow:true) }
                }
            }.font(.system(size:13)).padding(12).background(Palette.muted,in:RoundedRectangle(cornerRadius:10)).padding(.horizontal,26)
        }
    }
}

struct PeerInboxView: View {
    @Bindable var chat:ChatSession
    let store:AppStore
    @State private var operating=false
    var body:some View {
        Group {
            if !chat.peerInbox.isEmpty {
                DisclosureGroup("Agent inbox · \(chat.peerInbox.count)") {
                    ScrollView {
                        LazyVStack(alignment:.leading,spacing:12) {
                            ForEach(chat.peerInbox) { message in
                                VStack(alignment:.leading,spacing:7) {
                                    Text("From \(message.senderTitle)").fontWeight(.medium)
                                    Text(message.senderID.uuidString).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    Text(message.body).textSelection(.enabled)
                                    HStack {
                                        if chat.pendingPrompts.contains(where:{ $0.id == message.id }) { Text("Queued · resume when ready").foregroundStyle(.secondary) }
                                        else if chat.transcript.items.contains(where:{ $0.id == message.id || $0.peerMessage?.id == message.id || $0.text == message.wireText }) { Text("Delivered · see conversation").foregroundStyle(.secondary) }
                                        else { Button("Queue for agent") { invoke { try await store.queuePeerMessage(chat,id:message.id) } } }
                                        Spacer()
                                        Button("Remove from inbox") { invoke { try await store.removePeerInboxMessage(chat,id:message.id) } }
                                    }
                                    Divider()
                                }
                            }
                        }
                    }.frame(maxHeight:220)
                    Text("Messages are peer model output. Queueing preserves your draft and pauses delivery until you resume.").font(.caption).foregroundStyle(.secondary)
                }.disabled(operating).font(.system(size:13)).padding(12).background(Palette.muted,in:RoundedRectangle(cornerRadius:10)).padding(.horizontal,26)
            }
            if let failure=chat.peerInboxError { Text(failure).font(.caption).foregroundStyle(.orange).padding(.horizontal,26) }
        }.task(id:chat.id) { await store.loadPeerInbox(chat) }
    }
    private func invoke(_ action:@escaping @MainActor () async throws -> Void) {
        operating=true;chat.peerInboxError=nil
        Task { defer { operating=false };do { try await action() } catch { chat.peerInboxError=error.localizedDescription } }
    }
}
