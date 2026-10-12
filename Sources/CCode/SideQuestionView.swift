import SwiftUI
import CCodeCore

struct SideQuestionView: View {
    @Bindable var chat: ChatSession
    let store: AppStore
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "bubble.left.and.bubble.right")
                Text("Side question").fontWeight(.medium)
                Spacer()
                Button { store.closeSideQuestion(chat) } label: { Image(systemName: "xmark") }.help("Close and forget side question")
            }
            Text("Uses this conversation’s context. Cannot run tools or change files. Forgotten when closed.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !chat.sideQuestionHistory.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(chat.sideQuestionHistory.enumerated()), id: \.offset) { _, exchange in
                            Text(exchange.question).foregroundStyle(.secondary).textSelection(.enabled)
                            MarkdownText(text: exchange.response, streaming: false)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 150)
            }
            if let error=chat.sideQuestionError { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true) }
            DictationPreview(capture: store.dictation, destination: .sideQuestion(chat.id), draft: $chat.sideQuestionDraft)
            HStack {
                DictationButton(capture: store.dictation, destination: .sideQuestion(chat.id))
                TextField("Ask about this conversation…",text:$chat.sideQuestionDraft,axis:.vertical)
                    .textFieldStyle(.plain).lineLimit(1...3).focused($focused).onSubmit { store.askSideQuestion(chat) }
                if chat.sideQuestionOperation != nil {
                    ProgressView().controlSize(.small)
                    Button("Stop") { store.cancelSideQuestion(chat) }
                } else {
                    Button { store.askSideQuestion(chat) } label: { Image(systemName:"arrow.up") }
                        .disabled(chat.sideQuestionDraft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                        .help("Ask side question")
                }
            }.padding(10).background(Palette.surface,in:RoundedRectangle(cornerRadius:8))
        }.font(.system(size:13)).buttonStyle(.plain).padding(12)
            .background(Palette.muted,in:RoundedRectangle(cornerRadius:12))
            .padding(.horizontal,26).padding(.top,8).frame(maxWidth:872)
            .onAppear { focused=true }
            .onChange(of: focused) { _, value in chat.editingSideQuestion=value }
            .onDisappear { chat.editingSideQuestion=false }
    }
}
