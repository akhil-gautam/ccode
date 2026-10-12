import Foundation

public struct SessionInfo: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var projectPath: String
    public var worktreeSourcePath: String?
    public var title: String
    public var updatedAt: Date
    public var archived: Bool
    public var pinned: Bool
    public var lastError: String?
    public var agentExecutable: String?
    public var agentArguments: [String]?
    public var additionalDirectories: [String]?
    public var executionEnvironment: ExecutionEnvironment?
    public var remoteSessionID: String?
    public var importedFromAgent: Bool?
    public var agentTitle: String?
    public var agentUpdatedAt: Date?
    public var attention: SessionAttentionReceipt?
    public var origin: ConversationOrigin?
    public var scheduledOrigin: ScheduledOrigin?
    public init(id: UUID = UUID(), projectPath: String, title: String = "New session") {
        self.id = id; self.projectPath = projectPath; self.title = title
        updatedAt = Date(); archived = false; pinned = false
    }
    public var projectGroupingPath: String {
        let path = worktreeSourcePath ?? projectPath
        if case .ssh(let host) = environment { return "ssh://" + environment.identity + ":" + (host.resolvedOptionsDigest ?? "legacy") + path }
        return path
    }
    public var environment: ExecutionEnvironment { executionEnvironment ?? .local }
    public var projectName: String { URL(fileURLWithPath: worktreeSourcePath ?? projectPath).lastPathComponent }
}

public enum ToolInterruption: String, Codable, Sendable {
    case stopped, disconnected, interrupted
    public var label: String { rawValue.capitalized }
}

public struct TranscriptItem: Codable, Identifiable, Sendable, Equatable {
    public var id = UUID()
    public var kind: String
    public var text: String = ""
    public var tool: JSONValue = [:]
    public var blocks: [JSONValue] = []
    public var messageID: String?
    // Client-submitted snapshots and turn provenance; absent on imported/older messages.
    public var promptAttachments: [PromptAttachment]?
    public var startedSession: Bool?
    public var deliveryState: DeliveryState?
    public var deliveryStopReason: String?
    public var fileCheckpoint: FileCheckpointReference?
    // Client observation, separate from the provider's last tool status/result.
    public var peerMessage: PeerMessage?
    public var toolInterruption: ToolInterruption?
    public var isToolRunning: Bool {
        kind == "tool" && !["completed", "failed"].contains(tool["status"].string) && toolInterruption == nil
    }
    public init(kind: String, text: String = "", tool: JSONValue = [:], blocks: [JSONValue] = [], messageID: String? = nil) {
        self.kind = kind; self.text = text; self.tool = tool; self.blocks = blocks; self.messageID = messageID
    }
}

public struct SessionTranscript: Codable, Sendable {
    public var version = 1
    public var remoteID: String?
    // Own new identity before prompt submission; nil for existing/unknown identities.
    public var remoteUnprompted: Bool?
    public var items: [TranscriptItem] = [] { didSet { if !reducingItems { itemIndex = nil } } }
    public var plan: [JSONValue] = []
    public var configOptions: [JSONValue] = []
    public var modes: JSONValue = [:]
    public var models: JSONValue = [:]
    public var commands: [JSONValue] = []
    public var usage: JSONValue = [:]
    public var draftText: String?
    public var draftAttachments: [PromptAttachment]?
    public var editorDrafts: [String: EditorDraft]?
    public var workspaceDirectory: String?
    public var selectedEditorFile: String?
    public var editorFolder: String?
    public var workspacePane: String?
    public var pendingConfiguration: SessionConfiguration?
    public var historyUpdatedAt: Date?
    public var pendingPrompts: [PendingPrompt]?
    public var deliveryPaused: Bool?
    public var pendingSettings: [PendingSetting]?
    public var settingsPaused: Bool?
    public var failure: AgentFailure?
    public var subagents: [SubagentSession]?
    public var asyncTasks: [AgentAsyncTask]?
    public var fileRestorations: [FileCheckpointRestoration]?
    public var discards: [DiscardResult]?
    public var reviewComments: [ReviewComment]?
    public var codeReview: CodeReview?
    public var pullRequest: PullRequest?
    public var pullRequestOperation: PullRequestOperation?
    public var pullRequestAutoFix: PullRequestAutoFix?
    public var computerToolsEnabled: Bool?
    public var simulatorToolsEnabled: Bool?
    public var sessionToolsEnabled: Bool?
    public var browserToolsEnabled: Bool?
    public var previewLaunch: PreviewLaunchConfiguration?
    private var openMessage: UUID?
    private var reducingItems = false
    private var itemIndex: ItemIndex?
    private struct MessageKey: Hashable, Sendable { let kind: String; let id: String }
    private struct ItemIndex: Sendable {
        var messages: [MessageKey: Int] = [:]
        var tools: [String: Int] = [:]
        var openMessage: Int?
        var hasDuplicateIdentities = false
    }
    private enum CodingKeys: String, CodingKey {
        case version, remoteID, remoteUnprompted, items, plan, configOptions, modes, models, commands, usage, draftText, draftAttachments, editorDrafts, workspaceDirectory, selectedEditorFile, editorFolder, workspacePane, pendingConfiguration, historyUpdatedAt, openMessage, pendingPrompts, deliveryPaused, pendingSettings, settingsPaused, failure, subagents, asyncTasks, fileRestorations, discards, reviewComments, codeReview, pullRequest, pullRequestOperation, pullRequestAutoFix, computerToolsEnabled, simulatorToolsEnabled, sessionToolsEnabled, browserToolsEnabled, previewLaunch
    }
    private mutating func indexItems() {
        guard itemIndex == nil else { return }
        var index = ItemIndex()
        var identities: Set<UUID> = []
        for (position, item) in items.enumerated() {
            if !identities.insert(item.id).inserted { index.hasDuplicateIdentities = true }
            if let id = item.messageID { index.messages[MessageKey(kind: item.kind, id: id)] = position }
            if item.kind == "tool", let id = item.tool["toolCallId"].optionalString { index.tools[id] = position }
            if item.id == openMessage { index.openMessage = position }
        }
        itemIndex = index
    }
    public init(remoteID: String? = nil) { self.remoteID = remoteID }
    public mutating func interruptTools(_ reason: ToolInterruption) {
        for index in items.indices where items[index].isToolRunning { items[index].toolInterruption = reason }
    }
    // Read-only history replay cannot revive a tool stopped on this client.
    public mutating func restoreToolInterruptions(from saved: SessionTranscript) {
        guard remoteID != nil, remoteID == saved.remoteID else { return }
        let source = Dictionary(grouping: saved.items.filter { $0.kind == "tool" && !$0.tool["toolCallId"].string.isEmpty }, by: { $0.tool["toolCallId"].string })
        let target = Dictionary(grouping: items.indices.filter { items[$0].kind == "tool" && !items[$0].tool["toolCallId"].string.isEmpty }, by: { items[$0].tool["toolCallId"].string })
        for (id, positions) in target where positions.count == 1 {
            guard let previous = source[id], previous.count == 1, let reason = previous[0].toolInterruption else { continue }
            let index = positions[0]
            guard items[index].isToolRunning,
                  ["name", "title", "kind", "rawInput"].allSatisfy({ items[index].tool[$0] == previous[0].tool[$0] }) else { continue }
            items[index].toolInterruption = reason
        }
        let savedChildren = Dictionary(grouping: saved.subagents ?? [], by: \.id)
        let currentChildren = Dictionary(grouping: (subagents ?? []).indices, by: { subagents![$0].id })
        for (id, positions) in currentChildren where positions.count == 1 {
            guard let previous = savedChildren[id], previous.count == 1 else { continue }
            let index = positions[0]
            guard subagents?[index].parentID == previous[0].parentID else { continue }
            subagents?[index].transcript.restoreToolInterruptions(from: previous[0].transcript)
        }
    }
    public mutating func beginTurn() { openMessage = nil; itemIndex?.openMessage = nil }
    public mutating func appendUser(_ text: String, blocks: [JSONValue] = [], attachments: [PromptAttachment]? = nil, startedSession: Bool? = nil, id: UUID = UUID(), deliveryState: DeliveryState? = nil) {
        beginTurn()
        var item = TranscriptItem(kind: "user", text: text, blocks: blocks)
        item.promptAttachments = attachments; item.startedSession = startedSession
        item.id = id; item.deliveryState = deliveryState
        items.append(item)
    }
    public mutating func appendNotice(_ text: String) { items.append(TranscriptItem(kind: "notice", text: text)); openMessage = nil }
    public mutating func configure(_ result: JSONValue) {
        if !result["sessionId"].string.isEmpty { remoteID = result["sessionId"].string }
        if !result["configOptions"].isNull { configOptions = result["configOptions"].array }
        if !result["modes"].isNull { modes = result["modes"] }
        if !result["models"].isNull { models = result["models"] }
    }

    @discardableResult public mutating func apply(_ params: JSONValue) -> Bool {
        guard let remoteID, params["sessionId"].string == remoteID else { return false }
        reducingItems = true
        defer { reducingItems = false }
        let update = params["update"], kind = update["sessionUpdate"].string
        switch kind {
        case "agent_message_chunk", "agent_thought_chunk", "user_message_chunk":
            let role = kind == "user_message_chunk" ? "user" : kind == "agent_thought_chunk" ? "thought" : "assistant"
            let content = update["content"], messageID = update["messageId"].optionalString
            indexItems()
            let index = messageID.flatMap { itemIndex?.messages[MessageKey(kind: role, id: $0)] }
                ?? itemIndex?.openMessage.flatMap { items[$0].kind == role && items[$0].messageID == messageID ? $0 : nil }
                // Public edits can clone UUIDs; preserve the original filtered last-match behavior.
                ?? (itemIndex?.hasDuplicateIdentities == true ? openMessage.flatMap { id in items.lastIndex { $0.id == id && $0.kind == role && $0.messageID == messageID } } : nil)
            let target: Int
            if let index { target = index }
            else {
                items.append(TranscriptItem(kind: role, messageID: messageID)); target = items.count - 1
                if let messageID { itemIndex?.messages[MessageKey(kind: role, id: messageID)] = target }
            }
            if content["type"].string == "text" { items[target].text += content["text"].string }
            else { items[target].blocks.append(content) }
            openMessage = items[target].id
            itemIndex?.openMessage = target
        case "tool_call", "tool_call_update":
            let id = update["toolCallId"].string
            guard !id.isEmpty else { return false }
            indexItems()
            if let index = itemIndex?.tools[id] {
                items[index].tool = items[index].tool.merging(update)
                if ["pending", "in_progress", "completed", "failed"].contains(update["status"].string) {
                    items[index].toolInterruption = nil
                }
            } else {
                items.append(TranscriptItem(kind: "tool", tool: update)); openMessage = nil
                itemIndex?.tools[id] = items.count - 1; itemIndex?.openMessage = nil
            }
        case "plan": plan = update["entries"].array
        case "available_commands_update": commands = update["availableCommands"].array
        case "config_option_update": configOptions = update["configOptions"].array
        case "current_mode_update": modes["currentModeId"] = update["currentModeId"]
        case "current_model_update": models["currentModelId"] = update["currentModelId"]
        case "usage_update": usage = update
        case "session_info_update": break
        default: return false
        }
        return true
    }
}

public struct EditorDraft: Codable, Sendable {
    public var original: String
    public var text: String
    public init(original: String, text: String) { self.original = original; self.text = text }
}

public struct NewSessionDraft: Codable, Sendable, Equatable {
    public var projectPath: String { didSet { if projectPath != oldValue { branch = nil } } }
    public var text: String
    public var worktree: Bool
    public var branch: String?
    public var additionalDirectories: [String]?
    public var configuration: SessionConfiguration?
    public var attachments: [PromptAttachment]?
    public init(projectPath: String = "", text: String = "", worktree: Bool = false) {
        self.projectPath = projectPath; self.text = text; self.worktree = worktree
    }
}

public struct SessionConfiguration: Codable, Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var values: [String: JSONValue]
    public var defaultOptionIDs: Set<String>?
    public var legacyValues: [String: String]?
    public init(executable: String, arguments: [String], values: [String: JSONValue] = [:]) {
        self.executable = executable; self.arguments = arguments; self.values = values
    }
}

public struct AgentCatalog: Codable, Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var projectPath: String
    public var configOptions: [JSONValue]
    public var modes: JSONValue
    public var models: JSONValue
    public init(executable: String, arguments: [String], projectPath: String, configOptions: [JSONValue] = [], modes: JSONValue = [:], models: JSONValue = [:]) {
        self.executable = executable; self.arguments = arguments; self.projectPath = projectPath
        self.configOptions = configOptions; self.modes = modes; self.models = models
    }
}
