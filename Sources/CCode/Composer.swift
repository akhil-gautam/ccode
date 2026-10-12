import SwiftUI
import AppKit
import ImageIO
import CCodeCore

struct Composer: View {
    @Bindable var chat: ChatSession
    @Bindable var store: AppStore
    let info: SessionInfo
    @State private var contextRequest: UUID?
    @State private var approvalID: UUID?
    private var visibleApproval: Approval? { chat.approvals.first { $0.id == approvalID } ?? chat.approvals.first }
    var body: some View {
        VStack(spacing: 9) {
            if let interaction = chat.interactions.first {
                InteractionCard(interaction: interaction, chat: chat, store: store)
            }
            ForEach(chat.urlInteractions) { interaction in
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("\(chat.workOwnerName(interaction.sessionID)) · Waiting for \(interaction.host)…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Dismiss") { chat.urlInteractions.removeAll { $0.id == interaction.id } }.font(.caption).buttonStyle(.plain)
                }.padding(10).background(Palette.muted, in: RoundedRectangle(cornerRadius: 8))
            }
            if chat.approvals.count > 1 {
                Menu("\(chat.approvals.count) pending approvals") {
                    ForEach(chat.approvals) { approval in
                        Button(chat.workOwnerName(approval.request["sessionId"].optionalString) + " · " + approval.request["toolCall"]["title"].string) { approvalID = approval.id }
                    }
                }.menuStyle(.borderlessButton).font(.caption)
            }
            if let approval = visibleApproval { PermissionCard(chat: chat, store: store, approval: approval) }
            NativeAccessRequestsView(chat:chat,store:store)
            SessionToolRequestsView(chat:chat,store:store)
            PeerInboxView(chat:chat,store:store)
            PendingPromptsView(chat: chat, store: store)
            PendingSettingsView(chat: chat, store: store)
            FailureCard(chat: chat, store: store)
            LaunchChoiceRecoveryView(chat: chat, store: store)
            if !chat.repository.branch.isEmpty {
                HStack(spacing: 10) {
                    WorkspaceFolderMenu(chat: chat, store: store).foregroundStyle(.secondary)
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                    Text(chat.repository.branch).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button { store.togglePane("diff", for: chat) } label: {
                        HStack(spacing: 8) {
                            Text("\(chat.repository.files.count) changed \(chat.repository.files.count == 1 ? "file" : "files")").foregroundStyle(.secondary)
                            if let stats = chat.changeStatistics, !stats.isEmpty { ChangeStatisticsLabel(values: Array(stats.values)) }
                        }
                    }.buttonStyle(.plain).help("Review changes")
                }.font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 8).background(Palette.muted, in: RoundedRectangle(cornerRadius: 8))
            }
            if !chat.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) { HStack {
                    ForEach(chat.attachments) { attachment in
                        AttachmentChip(attachment: attachment, url: store.attachmentURL(attachment), disabled: chat.preparingPrompt) { Task { await store.removeAttachment(attachment, from: chat) } }
                    }
                } }
            }
            if chat.attachingFiles { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading files…").font(.caption).foregroundStyle(.secondary); Button("Cancel") { store.cancelAttachmentImports(chat) } }.frame(maxWidth: .infinity, alignment: .leading) }
            DictationPreview(capture: store.dictation, destination: .chat(chat.id), draft: $chat.draft)
            HStack(alignment: .bottom, spacing: 8) {
                ContextPromptEditor(text: $chat.draft, workspace: chat.workspace, commands: chat.transcript.commands,
                    attach: { candidate, query in await store.attachContext(candidate, to: chat, replacing: query) },
                    send: { store.send(chat) }, cancel: { store.stop(chat) }, contextRequest: contextRequest,
                    attachmentInput: { store.attachInputs($0, to: chat) }, attachmentError: { store.error = $0 })
                if chat.restoringFiles {
                    ProgressView().controlSize(.small).help("Restoring captured files…").padding(.bottom, 16)
                } else if chat.busy {
                    Button { store.stop(chat) } label: {
                        Image(systemName: "stop.fill").font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 30).background(Palette.muted, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).disabled(chat.state == .stopping).help("Stop response (Esc)").accessibilityLabel("Stop response").padding(.bottom, 10)
                }
                Button { store.send(chat) } label: {
                    Image(systemName: "return").font(.system(size: 16, weight: .medium)).foregroundStyle(!chat.draft.isEmpty || !chat.attachments.isEmpty ? .white : .secondary).frame(width: 30, height: 30).background(!chat.draft.isEmpty || !chat.attachments.isEmpty ? Palette.accent : .clear, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).disabled(!store.canDeliver(chat) || chat.attachingFiles || chat.draft.isEmpty && chat.attachments.isEmpty).help(chat.busy ? "Send follow-up (Enter)" : "Send (Enter)").accessibilityLabel(chat.busy ? "Send follow-up" : "Send").padding(.bottom, 10)
            }.padding(.leading, 6).padding(.trailing, 12).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12)).overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.13), lineWidth: 1) }
                .onDrop(of: [.fileURL, .image], isTargeted: nil) { store.attachProviders($0, to: chat) }
            ViewThatFits(in: .horizontal) {
                controls
                ScrollView(.horizontal, showsIndicators: false) { controls.fixedSize(horizontal: true, vertical: false) }.frame(height: 28)
            }
        }.disabled(chat.launching).frame(maxWidth: 780).padding(.horizontal, 26).padding(.top, 10).padding(.bottom, 16).frame(maxWidth: .infinity)
            .task(id: chat.id) { await store.refreshWorkspace(chat) }
    }
    private var controls: some View {
        HStack(spacing: 12) {
            Menu {
                Button("Attach files…") { store.attachFiles(chat) }
                Button("Attach project context…") { contextRequest = UUID() }
                Button("Side question    ⌘;") { store.toggleSideQuestion(chat) }
                Divider()
                Menu("Transcript view") {
                    ForEach([("Normal", "normal"), ("Thinking", "thinking"), ("Verbose", "verbose")], id: \.1) { entry in
                        Button(entry.0) { chat.displayMode = entry.1 }
                    }
                }
                ForEach(chat.transcript.configOptions.filter { $0["type"].string == "boolean" }, id: \.["id"]) { configMenu($0) }
                if chat.state == .running, store.supportsSteering(chat) {
                    Divider()
                    Button("Send correction to active turn") { chat.deliveryPolicy = .steer }
                    Button("Queue for next turn") { chat.deliveryPolicy = .nextTurn }
                }
            } label: { Image(systemName: "plus").frame(width: 24, height: 24) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Add files, context or a side question").accessibilityLabel("Add")
            DictationButton(capture: store.dictation, destination: .chat(chat.id))
            if chat.transcript.configOptions.isEmpty {
                LegacyMenu(state: chat.transcript.modes, model: false, disabled: !store.canChooseSettings(chat), pendingValue: chat.pendingSettings.first { $0.legacy && $0.key == "modeId" }?.value) { id in Task { await store.setLegacy(chat, key: "modeId", id: id) } }
            }
            ForEach(chat.transcript.configOptions.filter { $0["category"].string == "mode" }, id: \.["id"]) { configMenu($0) }
            Spacer(minLength: 12)
            ForEach(chat.transcript.configOptions.filter { $0["category"].string != "mode" && $0["type"].string != "boolean" }, id: \.["id"]) { configMenu($0) }
            if chat.transcript.configOptions.isEmpty {
                LegacyMenu(state: chat.transcript.models, model: true, disabled: !store.canChooseSettings(chat), pendingValue: chat.pendingSettings.first { $0.legacy && $0.key == "modelId" }?.value) { id in Task { await store.setLegacy(chat, key: "modelId", id: id) } }
            }
            if !chat.transcript.usage.isNull, chat.transcript.usage["size"].int > 0 {
                let fraction = min(1, max(0, Double(chat.transcript.usage["used"].int) / Double(chat.transcript.usage["size"].int)))
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 2)
                    Circle().trim(from: 0, to: fraction).stroke(fraction > 0.75 ? Color.orange : Color.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                }.frame(width: 12, height: 12).padding(4)
                    .help("Context: \(chat.transcript.usage["used"].int) / \(chat.transcript.usage["size"].int) tokens (\(Int(fraction * 100))%)")
                    .accessibilityLabel("Context usage: \(Int(fraction * 100)) percent")
            }
        }.font(.system(size: 14)).buttonStyle(.plain).padding(.horizontal, 6)
    }
    private func configMenu(_ option: JSONValue) -> some View {
        ConfigMenu(option: option, disabled: !store.canChooseSettings(chat), pendingValue: chat.pendingSettings.first { !$0.legacy && $0.key == option["id"].string }?.value) { value in
            Task { await store.setConfig(chat, id: option["id"].string, value: value) }
        }
    }
}

struct AttachmentChip: View {
    let attachment: Attachment
    let url: URL
    let disabled: Bool
    let remove: () -> Void
    @State private var preview = false
    var body: some View {
        HStack(spacing: 6) {
            Button { preview = true } label: {
                HStack(spacing: 6) {
                    if attachment.mimeType.hasPrefix("image/") { AttachmentImage(source: .file(url), pixelLimit: 80).frame(width: 28, height: 28) }
                    else { Image(systemName: attachment.mimeType.hasPrefix("audio/") ? "waveform" : attachment.mimeType == "application/pdf" ? "doc.richtext" : "paperclip") }
                    Text(attachment.url.lastPathComponent + (attachment.context?.startLine.map { ":\($0)–\(attachment.context?.endLine ?? $0)" } ?? "")).lineLimit(1)
                }
            }.buttonStyle(.plain).help("Preview \(attachment.url.lastPathComponent)")
                .popover(isPresented: $preview) {
                    VStack(spacing: 0) {
                        HStack { Text(attachment.url.lastPathComponent).lineLimit(1); Spacer(); Button("Close") { preview = false } }.padding(12)
                        Divider()
                        ArtifactPreview(url: url, revision: 0)
                    }.frame(width: 520, height: 400)
                }
            Button(action: remove) { Image(systemName: "xmark") }.buttonStyle(.plain).disabled(disabled).accessibilityLabel("Remove \(attachment.url.lastPathComponent)")
        }.font(.caption).padding(8).background(Palette.muted, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct AttachmentImage: View {
    enum Source: Hashable, Sendable { case file(URL), base64(String) }
    let source: Source
    var pixelLimit = 800
    @State private var image: CGImage?
    @State private var loaded = false
    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
            else if loaded { Image(systemName: "photo").foregroundStyle(.secondary).accessibilityLabel("Image preview unavailable") }
            else { ProgressView().controlSize(.small) }
        }.task(id: source) {
            image = nil; loaded = false
            let source = source, limit = pixelLimit
            let task = Task.detached(priority: .userInitiated) { Self.thumbnail(source, pixelLimit: limit) }
            let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled else { return }
            image = result; loaded = true
        }
    }
    nonisolated static func thumbnail(_ source: Source, pixelLimit: Int) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let decoder: CGImageSource?
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        switch source {
        case .file(let url): decoder = CGImageSourceCreateWithURL(url as CFURL, options)
        case .base64(let encoded):
            guard encoded.utf8.count < PromptAttachment.promptLimit, let data = Data(base64Encoded: encoded) else { return nil }
            decoder = CGImageSourceCreateWithData(data as CFData, options)
        }
        guard let decoder, !Task.isCancelled else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(decoder, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(1, min(pixelLimit, 1600)), kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

struct LegacyMenu: View {
    let state: JSONValue
    let model: Bool
    var disabled = false
    var pendingValue: JSONValue?
    let choose: (String) -> Void
    var body: some View {
        let choices = state[model ? "availableModels" : "availableModes"].array
        if !choices.isEmpty {
            ConfigMenu(option: ["name": .string(model ? "Model" : "Mode"), "type": "select", "currentValue": state[model ? "currentModelId" : "currentModeId"],
                "options": .array(choices.map { ["value": $0[model ? "modelId" : "id"], "name": $0["name"], "description": $0["description"]] })], disabled: disabled, pendingValue: pendingValue) { choose($0.string) }
        }
    }
}

struct ConfigMenu: View {
    let option: JSONValue
    var disabled = false
    var pendingValue: JSONValue?
    let choose: (JSONValue) -> Void
    private var choices: [JSONValue] { option["options"].array.flatMap { $0["options"].isNull ? [$0] : $0["options"].array } }
    var body: some View {
        if option["type"].string == "select" {
            Menu {
                ForEach(choices, id: \.["value"]) { choice in Button { choose(choice["value"]) } label: { HStack { Text(choice["name"].string); if choice["value"] == option["currentValue"] { Image(systemName: "checkmark") }; if choice["value"] == pendingValue { Image(systemName: "clock") } } } }
            } label: { HStack(spacing: 4) { Text(choices.first { $0["value"] == option["currentValue"] }?["name"].string ?? option["name"].string); if pendingValue != nil { Image(systemName: "clock").font(.caption2) } } }.menuStyle(.borderlessButton).fixedSize().disabled(disabled).help(pendingValue == nil ? option["description"].string : "Pending setting · applies before the next turn").accessibilityLabel(option["name"].string + ": " + (choices.first { $0["value"] == option["currentValue"] }?["name"].string ?? option["name"].string) + (pendingValue == nil ? "" : ", change pending"))
        } else if option["type"].string == "boolean" {
            Button { choose(.bool(!(pendingValue ?? option["currentValue"]).bool)) } label: { Label(option["name"].string, systemImage: pendingValue != nil ? "clock" : option["currentValue"].bool ? "checkmark.circle.fill" : "circle") }.disabled(disabled).help(pendingValue == nil ? option["description"].string : "Pending setting · applies before the next turn")
        }
    }
}

struct PromptEditor: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var text: String
    let placeholder: String
    let send: () -> Void
    let cancel: () -> Void
    var focusOnMount = false
    var isMainPrompt = false
    var selectionChanged: ((String, NSRange) -> Void)?
    var completionKey: ((UInt16) -> Bool)?
    var selectionRequest: PromptSelectionRequest?
    var attachmentInput: (([AttachmentInput]) -> Void)?
    var attachmentError: ((String) -> Void)?
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        let input = InputTextView()
        input.isEditable = isEnabled
        input.isRichText = false; input.isAutomaticQuoteSubstitutionEnabled = false; input.isAutomaticDashSubstitutionEnabled = false
        input.drawsBackground = false; input.font = .systemFont(ofSize: 14); input.textColor = .labelColor
        input.textContainerInset = NSSize(width: 10, height: 14)
        input.isVerticallyResizable = true; input.isHorizontallyResizable = false
        input.autoresizingMask = [.width]; input.textContainer?.widthTracksTextView = true
        input.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        input.delegate = context.coordinator; input.send = { context.coordinator.parent.send() }
        input.cancel = { context.coordinator.parent.cancel() }
        input.completionKey = { context.coordinator.parent.completionKey?($0) ?? false }
        input.attachmentInput = attachmentInput == nil ? nil : { context.coordinator.parent.attachmentInput?($0) }
        input.attachmentError = { context.coordinator.parent.attachmentError?($0) }
        input.placeholder = placeholder; input.focusOnMount = focusOnMount; input.setAccessibilityLabel("Prompt")
        if isMainPrompt { input.identifier = NSUserInterfaceItemIdentifier("ccode.mainPrompt") }
        scroll.documentView = input
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let input = scroll.documentView as? InputTextView else { return }
        input.isEditable = isEnabled
        input.attachmentInput = attachmentInput == nil ? nil : { context.coordinator.parent.attachmentInput?($0) }
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        if input.string != text { let selection = input.selectedRange(); input.string = text; input.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0)) }
        if let request = selectionRequest, request.id != context.coordinator.selectionID {
            context.coordinator.selectionID = request.id
            input.setSelectedRange(NSRange(location: min(request.caret, (text as NSString).length), length: 0))
            input.window?.makeFirstResponder(input)
        }
        input.needsDisplay = true
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptEditor
        var updating = false
        var selectionID: UUID?
        init(_ parent: PromptEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard !updating, let input = notification.object as? NSTextView else { return }
            parent.text = input.string; input.needsDisplay = true
            parent.selectionChanged?(input.string, input.selectedRange())
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let input = notification.object as? NSTextView else { return }
            parent.selectionChanged?(input.string, input.selectedRange())
        }
    }
}

final class InputTextView: NSTextView {
    var send: (() -> Void)?
    var cancel: (() -> Void)?
    var completionKey: ((UInt16) -> Bool)?
    var attachmentInput: (([AttachmentInput]) -> Void)?
    var attachmentError: ((String) -> Void)?
    var placeholder = ""
    var focusOnMount = false
    func acceptAttachmentPasteboard(_ board: NSPasteboard) -> Bool {
        guard isEditable, let attachmentInput else { return false }
        do {
            let inputs = try PromptPasteboard.inputs(from: board)
            guard !inputs.isEmpty else { return false }
            attachmentInput(inputs)
        } catch { attachmentError?(error.localizedDescription) }
        return true
    }
    override func paste(_ sender: Any?) {
        if !acceptAttachmentPasteboard(.general) { super.paste(sender) }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if focusOnMount, let window { window.makeFirstResponder(self) }
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
           [36, 48, 53, 125, 126].contains(event.keyCode), completionKey?(event.keyCode) == true { return }
        if event.keyCode == 53 && event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty { cancel?(); return }
        if event.keyCode == 36 && event.modifierFlags.intersection([.shift, .option, .control]).isEmpty { send?(); return }
        super.keyDown(with: event)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty { (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height), withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.placeholderTextColor]) }
    }
}
