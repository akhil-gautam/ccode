import AppKit
import Observation
import CCodeCore

enum RunState: String { case idle, connecting, ready, running, stopping, failed }
struct ChatPaneFocusRequest: Equatable {
    let id = UUID()
    let paneID: UUID
}

typealias Attachment = PromptAttachment
struct Approval: Identifiable {
    let id: UUID
    let request: JSONValue
    let continuation: CheckedContinuation<JSONValue, any Error>
    var error: String?
    var submittingRevision = false
    var previewTool: JSONValue?
    var toolCall: JSONValue { previewTool ?? request["toolCall"] }
}

struct PendingInteraction: Identifiable {
    let id: UUID
    let request: ElicitationRequest
    let continuation: CheckedContinuation<JSONValue, any Error>
}

struct URLInteraction: Identifiable {
    let id: String
    let host: String
    let message: String
    var sessionID: String? = nil
}

@MainActor @Observable final class ChatSession {
    let id: UUID
    var transcript: SessionTranscript
    @ObservationIgnored var activityDidChange: (() -> Void)?
    var state: RunState = .idle { didSet { if oldValue != state { activityDidChange?() } } }
    var configuring = false
    var liveConfigurationOperation: UUID?
    @ObservationIgnored var liveConfigurationTask: Task<LiveConfigurationResult, any Error>?
    var launching = false
    var preparingPrompt = false { didSet { if oldValue != preparingPrompt { activityDidChange?() } } }
    var forking = false
    var closing = false
    var restoringFiles = false
    var workspaceWrites = 0
    var selectingWorkspaceFolder = false
    @ObservationIgnored var workspaceActionTask: Task<Void, any Error>?
    @ObservationIgnored var pullRequestMonitor: Task<Void, Never>?
    @ObservationIgnored var pullRequestMonitorID: UUID?
    var pullRequestError: String?
    var submittingReview = false
    @ObservationIgnored var reviewOperation: UUID?
    var reviewComments: [ReviewComment] {
        get { transcript.reviewComments ?? [] }
        set { transcript.reviewComments = newValue.isEmpty ? nil : newValue }
    }
    @ObservationIgnored var fileRestoreOperation: UUID?
    @ObservationIgnored var fileRestoreTask: Task<FileCheckpointRestoration, Never>?
    @ObservationIgnored var discardOperation: UUID?
    @ObservationIgnored var discardTask: Task<DiscardResult, any Error>?
    var handshake: JSONValue = [:]
    var draft = ""
    var showSideQuestion = false
    var editingSideQuestion = false
    var sideQuestionDraft = ""
    var sideQuestionHistory: [SideQuestionExchange] = []
    var sideQuestionError: String?
    var sideQuestionOperation: UUID?
    @ObservationIgnored var sideQuestionTask: Task<Void, Never>?
    @ObservationIgnored var sideQuestionRequest: (peer: ACPConnection, session: String, connection: UUID, question: UUID)?
    var attachments: [Attachment] = []
    var attachingFiles = false
    @ObservationIgnored var pendingAttachmentInputs: [AttachmentInput] = []
    @ObservationIgnored var attachmentResidentBytes = 0
    @ObservationIgnored var attachmentTask: Task<Void, Never>?
    @ObservationIgnored var attachmentReservation = 0
    var approvals: [Approval] = [] { didSet { activityDidChange?() } }
    var interactions: [PendingInteraction] = [] { didSet { activityDidChange?() } }
    var urlInteractions: [URLInteraction] = [] { didSet { activityDidChange?() } }
    var repository = RepositoryStatus()
    var workspaceDirectory: String { transcript.workspaceDirectory ?? workspace.root }
    var selectedEditorFile: String? {
        get { transcript.selectedEditorFile }
        set { transcript.selectedEditorFile = newValue }
    }
    var editorFolder: String? {
        get { transcript.editorFolder }
        set { transcript.editorFolder = newValue }
    }
    var editorSelection = NSRange(location: 0, length: 0)
    var changeStatistics: [String: FileChangeStatistics]?
    var changeStatisticsError: String?
    @ObservationIgnored var workspaceRefreshID: UUID?
    @ObservationIgnored var workspaceStatisticsID: UUID?
    @ObservationIgnored var workspaceStatisticsTask: Task<Void, Never>?
    var workspaceRevision = UUID()
    var files: [String] = []
    var lastError: String? {
        didSet { if lastError != transcript.failure?.details { transcript.failure = nil }; if oldValue != lastError { activityDidChange?() } }
    }
    var failure: AgentFailure? {
        get { transcript.failure }
        set { transcript.failure = newValue }
    }
    var displayMode = "normal"
    var selectedSubagentID: String?
    var selectedAsyncTaskID: AsyncTaskIdentity?
    var asyncTaskErrors: [AsyncTaskIdentity: String] = [:]
    var stoppingAsyncTasks: Set<AsyncTaskIdentity> = []
    var subagentStopErrors: [String: String] = [:]
    var stoppingSubagents: Set<String> = []
    @ObservationIgnored var childOwners: Set<String> = []
    @ObservationIgnored var asyncTaskOwners: Set<AsyncTaskIdentity> = []
    var fileDrafts: [String: FileDraft] = [:]
    var terminalTabs: [TerminalTab] = []
    var activeTerminalID: UUID?
    var computerWorkspace = ComputerWorkspace()
    @ObservationIgnored lazy var simulatorWorkspace: SimulatorWorkspace = {
        let root=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/dev.ccode.native/simulator")
        let development=Bundle.main.object(forInfoDictionaryKey: "CCodeDevelopmentRoot") as? String ?? FileManager.default.currentDirectoryPath
        let helper=Bundle.main.url(forResource: "simulator-control", withExtension: "py") ?? URL(fileURLWithPath: development+"/scripts/simulator-control.py")
        return SimulatorWorkspace(service: SimulatorService(cache: root.appendingPathComponent(id.uuidString), helper: helper))
    }()
    @ObservationIgnored var nativeToolServer: BrowserToolServer?
    @ObservationIgnored var nativeToolEndpoint: BrowserToolEndpoint?
    @ObservationIgnored var nativeToolGeneration: UUID?
    @ObservationIgnored lazy var browserWorkspace = BrowserWorkspace()
    @ObservationIgnored lazy var previewServer = PreviewServer(workspace: workspace)
    var previewActive = false
    var previewStarting = false
    @ObservationIgnored var previewTask: Task<Void, any Error>?
    @ObservationIgnored var previewOperation: UUID?
    @ObservationIgnored var previewMonitor: Task<Void, Never>?
    var sessionToolApprovalCount = 0 { didSet { activityDidChange?() } }
    var peerInbox: [PeerMessage] = []
    var peerInboxError: String?
    @ObservationIgnored var sessionToolGeneration: UUID?
    @ObservationIgnored var sessionToolServer: BrowserToolServer?
    @ObservationIgnored var sessionToolEndpoint: BrowserToolEndpoint?
    @ObservationIgnored var connection: ACPConnection?
    @ObservationIgnored let workspace: Workspace
    @ObservationIgnored let terminals = TerminalService()
    @ObservationIgnored lazy var remotePullRequests = PullRequestService(workspace: workspace)
    @ObservationIgnored var promptTask: Task<Void, Never>?
    @ObservationIgnored var promptOperation: UUID?
    @ObservationIgnored var deliveryTask: Task<Void, Never>?
    @ObservationIgnored var deliveryOperation: UUID?
    var steeringUnavailable = false
    var deliveringPrompt = false
    var revisingPlan = false
    var persistingSettings = 0
    @ObservationIgnored var settingsTask: Task<Void, Never>?
    @ObservationIgnored var settingsOperation: UUID?
    @ObservationIgnored var settingsReview: UUID?
    var promptDeliveryID: UUID?
    var deliveryPolicy: DeliveryPolicy = .steer
    var pendingPrompts: [PendingPrompt] {
        get { transcript.pendingPrompts ?? [] }
        set { transcript.pendingPrompts = newValue.isEmpty ? nil : newValue }
    }
    var deliveryPaused: Bool {
        get { transcript.deliveryPaused == true }
        set { transcript.deliveryPaused = newValue ? true : nil }
    }
    var pendingSettings: [PendingSetting] {
        get { transcript.pendingSettings ?? [] }
        set { transcript.pendingSettings = newValue.isEmpty ? nil : newValue }
    }
    var settingsPaused: Bool {
        get { transcript.settingsPaused == true }
        set { transcript.settingsPaused = newValue ? true : nil }
    }
    @ObservationIgnored var saveTask: Task<Void, Never>?
    @ObservationIgnored var loadingHistory = false
    @ObservationIgnored var historyReplay: SessionTranscript?
    @ObservationIgnored var pendingSessionEvents: [JSONValue] = []
    @ObservationIgnored var sentPrompt = ""
    @ObservationIgnored var awaitingWorkCompletion = false
    @ObservationIgnored var connectionGeneration = UUID()
    @ObservationIgnored var setupGeneration = UUID()
    init(id: UUID, path: String, transcript: SessionTranscript, additionalDirectories: [String] = [], environment: ExecutionEnvironment = .local, sshExecutable: String = "/usr/bin/ssh") throws {
        self.id = id; self.transcript = transcript; workspace = try Workspace(root: path, additionalDirectories: additionalDirectories, environment: environment, sshExecutable: sshExecutable)
        if let selected = self.transcript.workspaceDirectory,
           !workspace.roots.contains(selected) || (environment.isLocal && (try? Workspace(root: selected).root) != selected) {
            self.transcript.workspaceDirectory = nil
        }
        if self.transcript.pullRequestOperation?.state == .preparing {
            self.transcript.pullRequestOperation?.state = .uncertain
            self.transcript.pullRequestOperation?.details = "GitHub operation was interrupted. Inspect GitHub before repeating it."
        }
        lastError = transcript.failure?.details
        self.transcript.interruptTools(.interrupted)
        self.transcript.disconnectSubagents()
        self.transcript.disconnectAsyncTasks()
        if self.transcript.codeReview?.status == .running {
            self.transcript.codeReview?.status = .interrupted
            self.transcript.codeReview?.findings = []
            self.transcript.codeReview?.details = "Review was interrupted. Request a fresh review when ready."
        }
        draft = transcript.draftText ?? ""; fileDrafts = transcript.editorDrafts ?? [:]
        if environment.isLocal, let key = selectedEditorFile {
            let file = URL(fileURLWithPath: workspace.filePath(key))
            let parent = try? Workspace(root: file.deletingLastPathComponent().path).root
            let full = parent.map { URL(fileURLWithPath: $0).appendingPathComponent(file.lastPathComponent).path }
            var directory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: file.path, isDirectory: &directory)
            let type = try? FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType
            if key.contains("\0") || full != file.path || !file.path.hasPrefix(workspaceDirectory == "/" ? "/" : workspaceDirectory + "/") || type == .typeSymbolicLink || directory.boolValue || (!exists && fileDrafts[key] == nil) { selectedEditorFile = nil }
        }
        if environment.isLocal, let folder = editorFolder {
            if (try? Workspace(root: folder).root) != folder || !(folder == workspaceDirectory || folder.hasPrefix(workspaceDirectory == "/" ? "/" : workspaceDirectory + "/")) { editorFolder = nil }
        }
        attachments = transcript.draftAttachments ?? []
        if self.transcript.fileRestorations != nil {
            for index in self.transcript.fileRestorations!.indices where self.transcript.fileRestorations![index].status == .preparing {
                self.transcript.fileRestorations![index].status = .uncertain
                self.transcript.fileRestorations![index].details = "Restoration was interrupted. Inspect files and recovery copies before trying again."
            }
        }
        if self.transcript.discards != nil {
            for index in self.transcript.discards!.indices where self.transcript.discards![index].status == .preparing {
                self.transcript.discards![index].status = .uncertain
                self.transcript.discards![index].details = "Discard was interrupted. Inspect files and recovery copies before trying again."
                deliveryPaused = true
            }
        }
        if !pendingSettings.isEmpty {
            settingsPaused = true
            for index in pendingSettings.indices where pendingSettings[index].state == .applying {
                pendingSettings[index].state = .uncertain
                pendingSettings[index].error = "Setting was interrupted. Review the current value before applying again."
            }
        }
        if !pendingPrompts.isEmpty {
            deliveryPaused = true
            for index in pendingPrompts.indices where pendingPrompts[index].state == .submitting {
                pendingPrompts[index].state = .uncertain
                pendingPrompts[index].error = "Delivery was interrupted. Check the agent history before sending again."
                if let row = self.transcript.items.firstIndex(where: { $0.id == pendingPrompts[index].id }) { self.transcript.items[row].deliveryState = .uncertain }
            }
        }
    }
    var busy: Bool { closing || launching || configuring || liveConfigurationOperation != nil || forking || preparingPrompt || deliveringPrompt || revisingPlan || persistingSettings > 0 || attachingFiles || restoringFiles || workspaceWrites > 0 || selectingWorkspaceFolder || submittingReview || previewStarting || [.connecting, .running, .stopping].contains(state) }
    var hasPendingDecisions: Bool { sessionToolApprovalCount > 0 || !approvals.isEmpty || !interactions.isEmpty || !urlInteractions.isEmpty }
    // Independent children can outlive a main turn without blocking its next prompt.
    var hasLiveAgentWork: Bool {
        hasPendingDecisions || (transcript.subagents ?? []).contains { childOwners.contains($0.id) && $0.isRunning }
            || (transcript.asyncTasks ?? []).contains { asyncTaskOwners.contains($0.id) && $0.isRunning }
    }
    var agentName: String { handshake["agentInfo"]["title"].optionalString ?? handshake["agentInfo"]["name"].optionalString ?? "ACP agent" }
    func ownsAgentSession(_ session: String) -> Bool { session == transcript.remoteID || childOwners.contains(session) }
    func workOwnerName(_ session: String?) -> String { session.flatMap { transcript.subagent($0)?.name } ?? agentName }
}

typealias FileDraft = EditorDraft

@MainActor @Observable final class AppStore {
    var nativeAccessRequests: [NativeAccessRequest] = []
    @ObservationIgnored var nativeAccessDecisions: [UUID: CheckedContinuation<Bool, Never>] = [:]
    @ObservationIgnored var simulatorLeases: [String: UUID] = [:]
    var sessionToolRequests: [SessionToolRequest] = []
    @ObservationIgnored var sessionToolDecisions: [UUID: CheckedContinuation<Bool, Never>] = [:]
    @ObservationIgnored var sessionToolMutations: Set<UUID> = []
    @ObservationIgnored var attentionNotifications: (any SessionNotificationDelivery)?
    var notificationStatus: String?
    @ObservationIgnored var sessionIsBeingViewed: ((UUID) -> Bool)?
    var showSSHWorkspaces = false
    var selectedSSHPresetID: UUID?
    var sessions: [SessionInfo] = [] { didSet { rebuildSidebar(); chatWindows?.scheduleSynchronize() } }
    private(set) var paneLayout = PaneLayout() { didSet { schedulePaneLayoutSave(); chatWindows?.scheduleSynchronize() } }
    @ObservationIgnored weak var chatWindows: ChatWindowCoordinator?
    @ObservationIgnored private var workflowOwners: [String: UUID] = [:]
    private(set) var chatPaneFocusRequest: ChatPaneFocusRequest?
    var selectedID: UUID? {
        get { paneLayout.focusedSessionID }
        set { paneLayout.show(newValue) }
    }
    private(set) var loadingSessions: [UUID: UUID] = [:]
    var loadingSessionID: UUID? { loadingSessions[paneLayout.focusedPaneID] }
    @ObservationIgnored private var paneLayoutSaveTask: Task<Void, Never>?
    @ObservationIgnored private var paneLoadGenerations: [UUID: UUID] = [:]
    func chat(_ id: UUID) -> ChatSession? { loaded[id] }
    func isChatVisible(_ id: UUID) -> Bool { paneLayout.visibleSessionIDs.contains(id) }
    func focusChatPane(_ id: UUID) {
        guard paneLayout.focusablePaneIDs.contains(id), paneLayout.focusedPaneID != id else { return }
        paneLayout.focus(id); selectionRevision += 1; recordVisit(selectedID)
    }
    func popOutChatPane(_ id: UUID) throws {
        guard !shuttingDown else { throw ACPError.workspace("The app is shutting down.") }
        try paneLayout.detach(id); selectionRevision += 1; recordVisit(selectedID)
    }
    func dockChatPane(_ id: UUID) throws {
        guard !shuttingDown else { throw ACPError.workspace("The app is shutting down.") }
        guard paneLayout.canDock(id) else { throw ACPError.workspace("Close a main-window chat pane before docking this window.") }
        chatWindows?.releaseWindow(for: id)
        try paneLayout.dock(id); selectionRevision += 1; recordVisit(selectedID)
    }
    func saveChatWindowFrame(_ frame: PaneWindowFrame, for id: UUID) { paneLayout.setWindowFrame(frame, for: id) }
    @discardableResult func popOutWorkspacePane(_ chat: ChatSession, kind: String) throws -> UUID {
        guard !shuttingDown, !chat.closing, loaded[chat.id] === chat else { throw ACPError.workspace("This conversation is unavailable.") }
        let id=try paneLayout.detachWorkspace(sessionID:chat.id,kind:kind)
        selectionRevision += 1;return id
    }
    func dockWorkspacePane(_ id: UUID) throws {
        guard !shuttingDown, let pane=paneLayout.detachedWorkspacePanes.first(where: { $0.id == id }), let chat=loaded[pane.sessionID], !chat.closing else { throw ACPError.workspace("This workspace window is unavailable.") }
        paneLayout.show(pane.sessionID)
        transferWorkflowOwners(from:id,to:paneLayout.focusedPaneID)
        chatWindows?.releaseWindow(for:id)
        paneLayout.closeWorkspace(id);setPane(pane.kind,for:chat);selectionRevision += 1
    }
    func closeWorkspacePane(_ id: UUID) async {
        guard !shuttingDown, let pane=paneLayout.detachedWorkspacePanes.first(where: { $0.id == id }) else { return }
        let root=paneLayout.allPanes.first(where: { $0.sessionID == pane.sessionID })?.id
        transferWorkflowOwners(from:id,to:root)
        chatWindows?.releaseWindow(for:id)
        if let chat=loaded[pane.sessionID], chat.transcript.workspacePane == pane.kind { setPane(nil,for:chat) }
        paneLayout.closeWorkspace(id);selectionRevision += 1
        if searchPaneID == id { closeSessionSearch() }
        await evictIdle(except:selectedID,revision:selectionRevision)
    }
    func closeFocusedWorkspacePane() async {
        if paneLayout.detachedWorkspacePanes.contains(where: { $0.id == paneLayout.focusedPaneID }) { await closeWorkspacePane(paneLayout.focusedPaneID) }
        else if let chat=selected { setPane(nil,for:chat) }
    }
    private func captureWorkflowOwner(_ key: String, sessionID: UUID?, active: Bool) {
        guard active else { workflowOwners.removeValue(forKey:key);return }
        workflowOwners[key]=paneLayout.sessionID(for:paneLayout.focusedPaneID) == sessionID ? paneLayout.focusedPaneID : paneLayout.allPanes.first(where: { $0.sessionID == sessionID })?.id
    }
    func workflowOwner(for key: String, sessionID: UUID?) -> UUID? {
        if let id=workflowOwners[key], paneLayout.focusablePaneIDs.contains(id), ["settings","error"].contains(key) || paneLayout.sessionID(for:id) == sessionID { return id }
        return paneLayout.allPanes.first(where: { $0.sessionID == sessionID })?.id
    }
    private func transferWorkflowOwners(from id: UUID, to replacement: UUID?) {
        for key in Array(workflowOwners.keys) where workflowOwners[key] == id { workflowOwners[key]=replacement }
    }
    func arrangeChatPanes(_ arrangement: PaneArrangement) { paneLayout.arrangement = arrangement }
    func focusNextChatPane() {
        let ids=paneLayout.focusablePaneIDs
        guard let index=ids.firstIndex(of:paneLayout.focusedPaneID) else { return }
        focusChatPane(ids[(index+1)%ids.count])
        chatPaneFocusRequest = ChatPaneFocusRequest(paneID: paneLayout.focusedPaneID)
    }
    func showSessionBeside(_ id: UUID) async throws {
        guard !shuttingDown, sessions.contains(where: { $0.id == id && !$0.archived }) else { throw ACPError.workspace("This session is unavailable.") }
        try paneLayout.showBeside(id)
        await select(id)
    }
    func closeChatPane(_ id: UUID) async {
        guard !shuttingDown, paneLayout.allPanes.contains(where: { $0.id == id }) else { return }
        if searchPaneID == id { closeSessionSearch() }
        nativeReadTasks.removeValue(forKey: id)?.cancel()
        paneLoadGenerations.removeValue(forKey: id); loadingSessions.removeValue(forKey: id)
        paneLayout.close(id); selectionRevision += 1
        await evictIdle(except: selectedID, revision: selectionRevision)
    }
    private func schedulePaneLayoutSave() {
        guard !loading, !shuttingDown else { return }
        paneLayoutSaveTask?.cancel()
        let snapshot = paneLayout
        paneLayoutSaveTask = Task { [weak self, storage] in
            do { try await Task.sleep(for: .milliseconds(150)); try Task.checkCancellation(); try await storage.savePaneLayout(snapshot) }
            catch is CancellationError { }
            catch { self?.error = "Could not save chat layout: \(error.localizedDescription)" }
        }
    }
    var search = "" { didSet { rebuildSessionSearch() } }
    var showArchived = false { didSet { rebuildSidebar() } }
    var showSidebar = true
    var showSessionSearch = false
    private(set) var searchPaneID: UUID?
    var checkpointPreviewRequest: FileCheckpointPreviewRequest? { didSet { if oldValue?.id != checkpointPreviewRequest?.id { captureWorkflowOwner("checkpoint",sessionID:checkpointPreviewRequest?.chat.id,active:checkpointPreviewRequest != nil) } } }
    var fileRestorationHistoryRequest: FileRestorationHistoryRequest? { didSet { if oldValue?.id != fileRestorationHistoryRequest?.id { captureWorkflowOwner("restorationHistory",sessionID:fileRestorationHistoryRequest?.chat.id,active:fileRestorationHistoryRequest != nil) } } }
    var discardPreviewRequest: DiscardPreviewRequest? { didSet { if oldValue?.id != discardPreviewRequest?.id { captureWorkflowOwner("discard",sessionID:discardPreviewRequest?.chat.id,active:discardPreviewRequest != nil) } } }
    var discardHistoryRequest: DiscardHistoryRequest? { didSet { if oldValue?.id != discardHistoryRequest?.id { captureWorkflowOwner("discardHistory",sessionID:discardHistoryRequest?.chat.id,active:discardHistoryRequest != nil) } } }
    var pullRequestDraftRequest: PullRequestDraftRequest? { didSet { if oldValue?.id != pullRequestDraftRequest?.id { captureWorkflowOwner("prDraft",sessionID:pullRequestDraftRequest?.chat.id,active:pullRequestDraftRequest != nil) } } }
    var pullRequestLogsRequest: PullRequestLogsRequest? { didSet { if oldValue?.id != pullRequestLogsRequest?.id { captureWorkflowOwner("prLogs",sessionID:pullRequestLogsRequest?.chatID ?? selectedID,active:pullRequestLogsRequest != nil) } } }
    var pullRequestMergeRequest: PullRequestMergeRequest? { didSet { if oldValue?.id != pullRequestMergeRequest?.id { captureWorkflowOwner("prMerge",sessionID:pullRequestMergeRequest?.chat.id,active:pullRequestMergeRequest != nil) } } }
    func closePullRequestMerge() {
        guard pullRequestMergeRequest?.applying != true else { return }
        let chat = pullRequestMergeRequest?.chat; pullRequestMergeRequest = nil
        if let chat { driveDelivery(chat) }
    }
    func closePullRequestDraft() {
        guard let request = pullRequestDraftRequest, !request.applying, !request.preparing else { return }
        pullRequestDraftRequest = nil; driveDelivery(request.chat)
    }
    var canSendPromptCommand: Bool { !showSessionSearch && !showNewBranch && !workspaceBranchEditing && !changingBranch && discardPreviewRequest == nil && discardHistoryRequest == nil && pullRequestDraftRequest == nil && pullRequestMergeRequest == nil && pullRequestLogsRequest == nil }
    func closeDiscardPreview() {
        guard discardPreviewRequest?.applying != true, discardPreviewRequest?.chat.restoringFiles != true else { return }
        discardPreviewRequest = nil
    }
    var showNewBranch = false
    var workspaceBranchEditing = false
    private(set) var searchProject: String?
    private(set) var sessionSearchResults: [SessionInfo] = []
    private(set) var sidebarPreferences = SidebarPreferences() { didSet { rebuildSidebar(); saveSidebarPreferences() } }
    @ObservationIgnored private var sidebarSaveTask: Task<Void, Never>?
    var pane: String? {
        get { selected.flatMap { pane(for: $0) } }
        set { if let chat = selected { setPane(newValue, for: chat) } }
    }
    func pane(for chat: ChatSession) -> String? {
        guard let pane = chat.transcript.workspacePane,
              DetachedWorkspacePane.kinds.contains(pane),
              !paneLayout.detachedWorkspacePanes.contains(where: { $0.sessionID == chat.id && $0.kind == pane }) else { return nil }
        return pane
    }
    func setPane(_ pane: String?, for chat: ChatSession) {
        guard !shuttingDown, !chat.closing, loaded[chat.id] === chat else { return }
        if let pane, !DetachedWorkspacePane.kinds.contains(pane) { return }
        if let pane, let floating=paneLayout.detachedWorkspacePanes.first(where: { $0.sessionID == chat.id && $0.kind == pane }) { focusChatPane(floating.id);return }
        chat.transcript.workspacePane = pane
        if chat.saveTask == nil {
            chat.saveTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                await self?.save(chat); chat.saveTask = nil
            }
        }
    }
    func togglePane(_ pane: String, for chat: ChatSession) {
        setPane(self.pane(for: chat) == pane ? nil : pane, for: chat)
    }
    var newSessionDraft = NewSessionDraft()
    var homeAttachingFiles = false
    @ObservationIgnored var homeAttachmentTask: Task<Void, Never>?
    @ObservationIgnored var pendingHomeAttachmentInputs: [AttachmentInput] = []
    @ObservationIgnored var homeAttachmentReservation = 0
    @ObservationIgnored var homeAttachmentResidentBytes = 0
    var canImportHomeAttachments: Bool { !startingSession && !shuttingDown }
    var homeConfigOptions: [JSONValue] = []
    private var homeModes: JSONValue = [:]
    private var homeModels: JSONValue = [:]
    private var homeConfigurationAgent: AgentSettings?
    var discoveringHomeOptions = false
    var homeDiscoveryError: String?
    var homeAuthMethods: [JSONValue] = []
    @ObservationIgnored private var homeDiscoveryPeer: ACPConnection?
    @ObservationIgnored private var homeDiscoveryContext: AgentCatalog?
    @ObservationIgnored private var homeDiscoveryGeneration = UUID()
    @ObservationIgnored private var homeDiscoveryCancelled = false
    var startingSession = false
    @ObservationIgnored private var homeLaunchTask: Task<Void, Never>?
    @ObservationIgnored private var homeBranchTask: Task<Bool, Never>?
    // ponytail: briefly serialize branch changes globally; use checkout locks if parallel launches need them.
    private(set) var changingBranch = false
    private(set) var shuttingDown = false
    var showSettings = false { didSet { if showSettings != oldValue { captureWorkflowOwner("settings",sessionID:selectedID,active:showSettings) } } }
    var settings = AgentSettings.load()
    var error: String? { didSet { if (error == nil) != (oldValue == nil) { captureWorkflowOwner("error",sessionID:selectedID,active:error != nil) } } }
    var loading = true
    private var loaded: [UUID: ChatSession] = [:]
    private var navigationHistory: [UUID?] = []
    private var navigationIndex = -1
    @ObservationIgnored private var selectionRevision = 0
    @ObservationIgnored private var nativeReadTasks: [UUID: Task<SessionTranscript?, Never>] = [:]
    @ObservationIgnored var pullRequests = PullRequestService()
    @ObservationIgnored var storage: SessionStorage
    var scheduledBook = ScheduledBook()
    var dictation = NativeDictation()
    var scheduledError: String?
    var showSchedules = false
    @ObservationIgnored var scheduleLoop: Task<Void, Never>?
    @ObservationIgnored var scheduledRunTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var scheduledCancellationRequests: Set<UUID> = []
    var canRunScheduledWork: Bool { !shuttingDown }
    @ObservationIgnored private var settingsURL: URL
    @ObservationIgnored private let worktreeDirectory: URL
    var selected: ChatSession? { selectedID.flatMap { loaded[$0] } }
    var selectedInfo: SessionInfo? { sessions.first { $0.id == selectedID } }
    func reloadAgentConfiguration(_ chat: ChatSession) async throws {
        guard !chat.busy, !chat.closing, !chat.hasLiveAgentWork, chat.pendingPrompts.isEmpty, chat.pendingSettings.isEmpty else { throw ACPError.workspace("Wait for this session's work and queued changes to finish before reconnecting.") }
        await disconnect(chat)
        try Task.checkCancellation()
        try await connect(chat)
        guard chat.state == .ready else { throw ACPError.workspace(chat.lastError ?? "The agent did not reconnect.") }
    }
    var sessionStatusFilter: SessionActivity? { didSet { rebuildSidebar() } }
    @ObservationIgnored private var runtimeActivities: [UUID: SessionActivity] = [:]
    private(set) var sidebarSnapshot = SidebarSnapshot()
    var visibleSessions: [SessionInfo] { sidebarSnapshot.visible }
    var sidebarProjects: [String] { sidebarSnapshot.projects }
    var sidebarSessionOrder: [SessionInfo] { sidebarSnapshot.sessionOrder }
    private func rebuildSidebar() {
        sidebarSnapshot = SidebarSnapshot(sessions: sessions, archived: showArchived, preferences: sidebarPreferences, activities: runtimeActivities, status: sessionStatusFilter)
        rebuildSessionSearch()
    }
    private func rebuildSessionSearch() {
        sessionSearchResults = showSessionSearch ? SidebarSnapshot(sessions: sessions, search: search, archived: showArchived, projectScope: searchProject).visible : []
    }
    func openSessionSearch(project: String? = nil) {
        searchPaneID = paneLayout.focusedPaneID; searchProject = project; showSessionSearch = true; search = ""
    }
    func closeSessionSearch() { searchPaneID = nil; showSessionSearch = false; searchProject = nil; search = "" }
    func composeFromSessionSearch() async {
        guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let text = search, project = searchProject
        closeSessionSearch(); newSessionDraft.text = text
        await openHome(path: project)
    }
    func toggleProjectCollapsed(_ path: String) {
        var next = sidebarPreferences
        if !next.collapsedProjects.insert(path).inserted { next.collapsedProjects.remove(path) }
        sidebarPreferences = next
    }
    func setAllProjectsCollapsed(_ collapsed: Bool) {
        var next = sidebarPreferences
        next.collapsedProjects = collapsed ? next.collapsedProjects.union(sidebarProjects) : []
        sidebarPreferences = next
    }
    func toggleProjectPin(_ path: String) {
        var next = sidebarPreferences
        if !next.pinnedProjects.insert(path).inserted { next.pinnedProjects.remove(path) }
        sidebarPreferences = next
    }
    func moveProject(_ source: String, before destination: String) {
        guard source != destination, sidebarProjects.contains(source), sidebarProjects.contains(destination),
              sidebarPreferences.pinnedProjects.contains(source) == sidebarPreferences.pinnedProjects.contains(destination) else { return }
        var order = sidebarProjects.filter { $0 != source }
        order.insert(source, at: order.firstIndex(of: destination)!)
        saveProjectOrder(order)
    }
    func canMoveProject(_ path: String, by offset: Int) -> Bool {
        guard let index = sidebarProjects.firstIndex(of: path), sidebarProjects.indices.contains(index + offset) else { return false }
        return sidebarPreferences.pinnedProjects.contains(path) == sidebarPreferences.pinnedProjects.contains(sidebarProjects[index + offset])
    }
    func moveProject(_ path: String, by offset: Int) {
        guard canMoveProject(path, by: offset), let index = sidebarProjects.firstIndex(of: path) else { return }
        var order = sidebarProjects
        order.swapAt(index, index + offset); saveProjectOrder(order)
    }
    private func saveProjectOrder(_ order: [String]) {
        let visible = Set(order)
        var seen = Set<String>(), reordered = order.makeIterator()
        var merged = sidebarPreferences.projectOrder.filter { seen.insert($0).inserted }
            .map { visible.contains($0) ? reordered.next()! : $0 }
        while let path = reordered.next() { merged.append(path) }
        var next = sidebarPreferences; next.projectOrder = merged; sidebarPreferences = next
    }
    private func saveSidebarPreferences() {
        let previous = sidebarSaveTask, value = sidebarPreferences
        sidebarSaveTask = Task { [storage] in
            await previous?.value
            do { try await storage.saveSidebarPreferences(value) }
            catch { self.error = "Could not save sidebar: \(error.localizedDescription)" }
        }
    }
    var refreshingSessionHistory = false
    var sessionHistoryError: String?
    @ObservationIgnored private var sessionHistoryPeer: ACPConnection?
    func refreshSessionHistory() async {
        guard !shuttingDown, !refreshingSessionHistory else { return }
        let agent = settings
        guard agent.executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: agent.executable) else { return }
        refreshingSessionHistory = true; sessionHistoryError = nil
        defer { refreshingSessionHistory = false }
        let peer = ACPConnection(onUpdates: { _ in }, onRequest: { method, _ in throw ACPError.methodNotFound(method) })
        sessionHistoryPeer = peer
        do {
            try await peer.start(executable: agent.executable, arguments: agent.arguments, directory: FileManager.default.homeDirectoryForCurrentUser.path, environment: AgentSettings.environment)
            let result = try await peer.request("initialize", params: ["protocolVersion": 1, "clientCapabilities": [:], "clientInfo": ["name": "ccode", "version": "0.1.0"]], timeout: .seconds(15))
            guard result["protocolVersion"].int == 1 else { throw ACPError.protocolViolation("Unsupported agent protocol version.") }
            guard case .object = result["agentCapabilities"]["sessionCapabilities"]["list"] else { await peer.close(); sessionHistoryPeer = nil; return }
            let catalog = try await peer.sessionCatalog()
            await peer.close(); sessionHistoryPeer = nil
            try Task.checkCancellation()
            guard !shuttingDown, settings.executable == agent.executable, settings.arguments == agent.arguments else { return }
            var migrations: [UUID: String] = [:]
            // Legacy summaries lack remote IDs. Use loaded history first and tolerate a damaged file.
            for info in sessions where info.environment.isLocal && info.remoteSessionID == nil && info.agentExecutable == agent.executable && info.agentArguments == agent.arguments {
                if let id = loaded[info.id]?.transcript.remoteID { migrations[info.id] = id }
                else {
                    do { if let id = try await storage.load(info.id).remoteID { migrations[info.id] = id } }
                    catch { sessionHistoryError = "Skipped unreadable local history: " + error.localizedDescription }
                }
            }
            // A connection, rename or archive may finish during those storage awaits.
            var merged = sessions
            for i in merged.indices where merged[i].environment.isLocal && merged[i].remoteSessionID == nil {
                if let remote = loaded[merged[i].id]?.transcript.remoteID ?? migrations[merged[i].id] { merged[i].remoteSessionID = remote }
            }
            var lookup: [String: Int] = [:]
            for i in merged.indices where merged[i].environment.isLocal && merged[i].agentExecutable == agent.executable && merged[i].agentArguments == agent.arguments {
                if let id = merged[i].remoteSessionID { lookup[id] = i }
            }
            for summary in catalog {
                if let i = lookup[summary.sessionID] {
                    if merged[i].importedFromAgent == true && loaded[merged[i].id]?.busy != true {
                        if merged[i].title == merged[i].agentTitle { merged[i].title = summary.title }
                        merged[i].agentTitle = summary.title
                        merged[i].agentUpdatedAt = summary.updatedAt == .distantPast ? nil : summary.updatedAt
                        merged[i].updatedAt = max(merged[i].updatedAt, summary.updatedAt)
                    }
                } else {
                    var info = SessionInfo(projectPath: summary.cwd, title: summary.title)
                    info.remoteSessionID = summary.sessionID; info.importedFromAgent = true; info.agentTitle = summary.title
                    info.agentExecutable = agent.executable; info.agentArguments = agent.arguments; info.updatedAt = summary.updatedAt
                    info.agentUpdatedAt = summary.updatedAt == .distantPast ? nil : summary.updatedAt
                    if case .object = result["agentCapabilities"]["sessionCapabilities"]["additionalDirectories"] { info.additionalDirectories = summary.additionalDirectories }
                    lookup[summary.sessionID] = merged.count; merged.append(info)
                }
            }
            guard !shuttingDown, settings.executable == agent.executable, settings.arguments == agent.arguments else { return }
            if merged != sessions { sessions = merged; try await storage.saveIndex(sessions) }
        } catch {
            await peer.close(); sessionHistoryPeer = nil
            if !shuttingDown, !Task.isCancelled { sessionHistoryError = error.localizedDescription }
        }
    }
    var canGoBack: Bool { historyDestination(-1) != nil }
    var canGoForward: Bool { historyDestination(1) != nil }
    var canGoToPreviousSession: Bool { neighboringSession(-1) != nil }
    var canGoToNextSession: Bool { neighboringSession(1) != nil }
    func goBack() async { await navigateHistory(-1) }
    func goForward() async { await navigateHistory(1) }
    func previousSession() async { if let id = neighboringSession(-1) { await select(id) } }
    func nextSession() async { if let id = neighboringSession(1) { await select(id) } }
    private func neighboringSession(_ direction: Int) -> UUID? {
        let order = sidebarSessionOrder
        guard let index = order.firstIndex(where: { $0.id == selectedID }) else { return direction < 0 ? order.last?.id : order.first?.id }
        let destination = index + direction
        return order.indices.contains(destination) ? order[destination].id : nil
    }
    private func recordVisit(_ id: UUID?) {
        guard navigationHistory.indices.contains(navigationIndex) == false || navigationHistory[navigationIndex] != id else { return }
        navigationHistory = Array(navigationHistory.prefix(navigationIndex + 1))
        navigationHistory.append(id); navigationIndex = navigationHistory.count - 1
    }
    private func historyDestination(_ direction: Int) -> Int? {
        let live = Set(sessions.lazy.filter { !$0.archived }.map(\.id))
        if direction < 0 { return navigationHistory.indices.reversed().first { $0 < navigationIndex && navigationHistory[$0] != selectedID && (navigationHistory[$0].map(live.contains) ?? true) } }
        return navigationHistory.indices.first { $0 > navigationIndex && navigationHistory[$0] != selectedID && (navigationHistory[$0].map(live.contains) ?? true) }
    }
    private func navigateHistory(_ direction: Int) async {
        guard let index = historyDestination(direction) else { return }
        navigationIndex = index
        if let id = navigationHistory[index] { await select(id, recordingHistory: false) }
        else { await openHome(recordingHistory: false) }
    }
    @ObservationIgnored let sshExecutable: String
    @ObservationIgnored let terminalEnvironment: [String: String]?
    init(directory: URL? = nil, claudeDirectory: URL? = nil, sshExecutable: String = "/usr/bin/ssh", terminalEnvironment: [String: String]? = nil) {
        self.sshExecutable = sshExecutable; self.terminalEnvironment = terminalEnvironment
        let override = ProcessInfo.processInfo.environment["CCODE_DATA_DIR"]
        let folder = directory ?? override.map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ccode", isDirectory: true)
        settingsURL = folder; storage = SessionStorage(directory: folder, claudeDirectory: claudeDirectory)
        worktreeDirectory = folder.appendingPathComponent("worktrees", isDirectory: true)
    }
    func restore() async {
        do { sidebarPreferences = try await storage.loadSidebarPreferences() }
        catch { self.error = "Could not load sidebar: \(error.localizedDescription)" }
        do {
            sessions = try await storage.list()
            for index in sessions.indices where sessions[index].attention?.kind == .needsInput {
                attentionNotifications?.clear(sessionID: sessions[index].id)
                sessions[index].attention = nil // Decision continuations cannot survive process restart.
            }
            newSessionDraft = try await storage.loadNewSessionDraft() ?? NewSessionDraft(projectPath: sessions.filter { !$0.archived }.max(by: { $0.updatedAt < $1.updatedAt })?.projectPath ?? "", worktree: settings.defaultWorktree)
            let restored: PaneLayout?
            do { restored = try await storage.loadPaneLayout() }
            catch { restored = nil; self.error = "Could not restore chat layout: \(error.localizedDescription)" }
            if var restored {
                restored.reconcile(available: Set(sessions.filter { !$0.archived }.map(\.id)))
                paneLayout = restored
                for id in restored.visibleSessionIDs { await select(id, recordingHistory: false) }
                paneLayout = restored
                recordVisit(selectedID)
            } else if let first = sessions.filter({ !$0.archived }).max(by: { $0.updatedAt < $1.updatedAt }) { await select(first.id) }
            else { recordVisit(nil) }
        } catch { self.error = "Could not load history: \(error.localizedDescription)" }
        loading = false
        schedulePaneLayoutSave()
    }
    func select(_ id: UUID, recordingHistory: Bool = true) async {
        guard !shuttingDown, let info = sessions.first(where: { $0.id == id }) else { return }
        let leavingHome = selectedID == nil
        if recordingHistory { recordVisit(id) }
        selectionRevision += 1
        selectedID = id
        let paneID = paneLayout.focusedPaneID, generation = UUID()
        nativeReadTasks.removeValue(forKey: paneID)?.cancel()
        paneLoadGenerations[paneID] = generation; loadingSessions[paneID] = id
        func ownsLoad() -> Bool {
            !shuttingDown && paneLoadGenerations[paneID] == generation && paneLayout.allPanes.contains { $0.id == paneID && $0.sessionID == id }
        }
        defer { if paneLoadGenerations[paneID] == generation { loadingSessions.removeValue(forKey: paneID); paneLoadGenerations.removeValue(forKey: paneID) } }
        if leavingHome { await cancelHomeDiscovery(); await saveNewSessionDraft(); guard ownsLoad() else { return } }
        if loaded[id] == nil {
            do {
                var transcript = try await storage.load(id)
                if transcript.remoteID == nil { transcript.remoteID = info.remoteSessionID }
                guard ownsLoad() else { return }
                let chat = try ChatSession(id: id, path: info.projectPath, transcript: transcript, additionalDirectories: info.additionalDirectories ?? [], environment: info.environment, sshExecutable: sshExecutable)
                if let error = info.lastError { chat.state = .failed; chat.lastError = error }
                loaded[id] = chat; observeAttention(chat)
            } catch {
                if ownsLoad() { paneLayout.close(paneID); self.error = error.localizedDescription }
                return
            }
        }
        guard let chat = loaded[id] else { return }
        guard ownsLoad() else { return }
        acknowledgeVisibleCompletions()
        async let cleanup: Void = evictIdle(except: selectedID, revision: selectionRevision)
        // ponytail: catalogs without timestamps reuse history for 30 seconds; provider timestamps invalidate immediately.
        let freshness = info.agentUpdatedAt ?? Date().addingTimeInterval(-30)
        if info.importedFromAgent == true, !chat.busy, !chat.hasLiveAgentWork,
           chat.transcript.historyUpdatedAt == nil || (chat.transcript.historyUpdatedAt ?? .distantPast) < freshness {
            let executable = info.agentExecutable ?? settings.executable
            let arguments = info.agentArguments ?? settings.arguments
            let usesClaudeACP = AgentSettings.usesClaudeHistory(executable: executable, arguments: arguments)
            let native: SessionTranscript?
            if info.environment.isLocal, usesClaudeACP, let remoteID = chat.transcript.remoteID {
                let read = Task { [storage] in try? await storage.loadClaudeTranscript(sessionID: remoteID, cwd: info.projectPath) }
                nativeReadTasks[paneID] = read; native = await read.value
                if paneLoadGenerations[paneID] == generation { nativeReadTasks.removeValue(forKey: paneID) }
            } else { native = nil }
            guard ownsLoad(), loaded[id] === chat, !chat.busy, !chat.hasLiveAgentWork else { await cleanup; return }
            if var native {
                native.workspacePane = chat.transcript.workspacePane
                native.restoreToolInterruptions(from: chat.transcript)
                native.interruptTools(.interrupted)
                native.pullRequest = chat.transcript.pullRequest
                native.pullRequestOperation = chat.transcript.pullRequestOperation
                native.pullRequestAutoFix = chat.transcript.pullRequestAutoFix
                native.browserToolsEnabled = chat.transcript.browserToolsEnabled
                native.computerToolsEnabled = chat.transcript.computerToolsEnabled
                native.simulatorToolsEnabled = chat.transcript.simulatorToolsEnabled
                native.sessionToolsEnabled = chat.transcript.sessionToolsEnabled
                native.previewLaunch = chat.transcript.previewLaunch
                native.pendingConfiguration = chat.transcript.pendingConfiguration
                native.pendingPrompts = chat.transcript.pendingPrompts
                native.deliveryPaused = chat.transcript.deliveryPaused
                native.pendingSettings = chat.transcript.pendingSettings
                native.settingsPaused = chat.transcript.settingsPaused
                native.failure = chat.transcript.failure
                native.subagents = native.subagents ?? chat.transcript.subagents
                native.mergeClaudeHistoricalTasks(from: chat.transcript)
                native.configOptions = chat.transcript.configOptions; native.modes = chat.transcript.modes; native.models = chat.transcript.models
                native.commands = chat.transcript.commands; native.usage = chat.transcript.usage
                native.historyUpdatedAt = info.agentUpdatedAt ?? Date()
                chat.transcript = native
                if chat.connection != nil { chat.state = .connecting; await disconnect(chat) }
                await save(chat)
            } else {
                do { try await connect(chat, reloadHistory: true) }
                catch { if !(error is CancellationError) { chat.lastError = error.localizedDescription } }
            }
        }
        await cleanup
        if selectedID != id { await evictIdle(except: selectedID, revision: selectionRevision) }
    }
    var attentionSessions: [SessionInfo] {
        sessions.filter { !$0.archived && [SessionActivity.needsAttention, .completed].contains(sessionActivity($0.id)) }.sorted { $0.updatedAt > $1.updatedAt }
    }
    func dismissAttention(_ id: UUID) {
        guard loaded[id]?.hasPendingDecisions != true else { return }
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].lastError = nil; loaded[id]?.lastError = nil
            sessions[index].attention = nil; attentionNotifications?.clear(sessionID: id)
            refreshChatActivity(id); persistIndex()
        }
    }
    func openHome(path: String? = nil, recordingHistory: Bool = true) async {
        guard !shuttingDown else { return }
        if let path, path.hasPrefix("ssh://"), let info = sessions.first(where: { $0.projectGroupingPath == path }), case .ssh(let host) = info.environment {
            let preset = try? SSHConnectionPreset(host: host, projectPath: info.projectPath, executable: info.agentExecutable ?? "claude-agent-acp", arguments: info.agentArguments ?? [])
            if let preset, !(settings.sshConnections ?? []).contains(where: { $0.id == preset.id }) { settings.sshConnections = (settings.sshConnections ?? []) + [preset]; settings.save() }
            selectedSSHPresetID = host.id; showSSHWorkspaces = true; return
        }
        let paneID = paneLayout.focusedPaneID
        selectionRevision += 1; let revision = selectionRevision
        if let path { newSessionDraft.projectPath = path }
        if recordingHistory { recordVisit(nil) }
        selectedID = nil; pane = nil
        if paneLayout.panes.first(where: { $0.id == paneID })?.sessionID == nil {
            nativeReadTasks.removeValue(forKey: paneID)?.cancel()
            paneLoadGenerations.removeValue(forKey: paneID); loadingSessions.removeValue(forKey: paneID)
        }
        await cancelHomeDiscovery()
        await saveNewSessionDraft()
        await evictIdle(except: nil, revision: revision)
        await refreshHomeConfiguration()
    }
    private func homeMatches(_ context: AgentCatalog, revision: Int) -> Bool {
        !shuttingDown && selectedID == nil && selectionRevision == revision && newSessionDraft.projectPath == context.projectPath && settings.executable == context.executable && settings.arguments == context.arguments
    }
    private func installHomeOptions(_ options: [JSONValue], modes: JSONValue, models: JSONValue, agent: AgentSettings) {
        homeConfigOptions = options; homeConfigurationAgent = agent
        homeModes = modes; homeModels = models
        if newSessionDraft.configuration == nil { newSessionDraft.configuration = SessionConfiguration(executable: agent.executable, arguments: agent.arguments) }
        // Only the displayed API family supplies launch choices after a catalog refresh.
        if !options.isEmpty { newSessionDraft.configuration?.legacyValues = nil }
        else if !modes["availableModes"].array.isEmpty || !models["availableModels"].array.isEmpty { newSessionDraft.configuration?.values = [:]; newSessionDraft.configuration?.defaultOptionIDs = nil }
        for option in options where newSessionDraft.configuration?.values[option["id"].string] == nil {
            if ["select", "boolean"].contains(option["type"].string) {
                newSessionDraft.configuration?.values[option["id"].string] = option["currentValue"]
                if newSessionDraft.configuration?.defaultOptionIDs == nil { newSessionDraft.configuration?.defaultOptionIDs = [] }
                newSessionDraft.configuration?.defaultOptionIDs?.insert(option["id"].string)
            }
        }
        if options.isEmpty {
            for (key, value) in [("modeId", modes["currentModeId"]), ("modelId", models["currentModelId"])] {
                if let id = value.optionalString, !id.isEmpty, newSessionDraft.configuration?.legacyValues?[key] == nil {
                    if newSessionDraft.configuration?.legacyValues == nil { newSessionDraft.configuration?.legacyValues = [:] }
                    newSessionDraft.configuration?.legacyValues?[key] = id
                }
            }
        }
    }
    @discardableResult func cancelHomeDiscovery() async -> UUID {
        homeLaunchTask?.cancel()
        homeDiscoveryCancelled = true
        let generation = UUID(); homeDiscoveryGeneration = generation
        guard let peer = homeDiscoveryPeer else { return generation }
        await peer.close()
        if homeDiscoveryPeer === peer { homeDiscoveryPeer = nil; discoveringHomeOptions = false }
        return generation
    }
    func refreshHomeConfiguration(force: Bool = false, authentication: String? = nil) async {
        guard !shuttingDown, selectedID == nil, !startingSession else { return }
        let revision = selectionRevision, agent = settings
        let context = AgentCatalog(executable: agent.executable, arguments: agent.arguments, projectPath: newSessionDraft.projectPath)
        if force || homeDiscoveryContext != context {
            let cancellation = await cancelHomeDiscovery()
            guard cancellation == homeDiscoveryGeneration, homeMatches(context, revision: revision), !Task.isCancelled else { return }
            homeDiscoveryContext = context; homeDiscoveryCancelled = false; homeDiscoveryError = nil; homeAuthMethods = []
        }
        guard !discoveringHomeOptions else { return }
        let generation = homeDiscoveryGeneration
        if homeConfigurationAgent?.executable != agent.executable || homeConfigurationAgent?.arguments != agent.arguments { homeConfigOptions = []; homeConfigurationAgent = nil }
        if let configuration = newSessionDraft.configuration, configuration.executable != agent.executable || configuration.arguments != agent.arguments { newSessionDraft.configuration = nil }
        if !force {
            for info in sessions.sorted(by: { $0.updatedAt > $1.updatedAt }) where info.environment.isLocal && info.agentExecutable == agent.executable && info.agentArguments == agent.arguments {
                let transcript: SessionTranscript?
                if let chat = loaded[info.id] { transcript = chat.transcript }
                else { transcript = try? await storage.load(info.id) }
                guard generation == homeDiscoveryGeneration, homeMatches(context, revision: revision), !Task.isCancelled else { return }
                if let transcript, !transcript.configOptions.isEmpty || !transcript.modes["availableModes"].array.isEmpty || !transcript.models["availableModels"].array.isEmpty {
                    installHomeOptions(transcript.configOptions, modes: transcript.modes, models: transcript.models, agent: agent); return
                }
            }
            if let cached = try? await storage.loadAgentCatalog(), cached.executable == context.executable, cached.arguments == context.arguments, cached.projectPath == context.projectPath {
                guard generation == homeDiscoveryGeneration, homeMatches(context, revision: revision), !Task.isCancelled else { return }
                installHomeOptions(cached.configOptions, modes: cached.modes, models: cached.models, agent: agent); return
            }
            if homeDiscoveryError != nil || homeDiscoveryCancelled { return }
        }
        guard generation == homeDiscoveryGeneration, homeMatches(context, revision: revision), !discoveringHomeOptions, !Task.isCancelled, !context.projectPath.isEmpty else { return }
        let peer = ACPConnection(onUpdates: { _ in }, onRequest: { method, _ in throw ACPError.methodNotFound(method) })
        homeDiscoveryPeer = peer; discoveringHomeOptions = true
        defer { if homeDiscoveryPeer === peer { homeDiscoveryPeer = nil; discoveringHomeOptions = false } }
        do {
            let workspace = try Workspace(root: context.projectPath)
            guard agent.executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: agent.executable) else { throw ACPError.workspace("Choose an installed ACP executable in Customize.") }
            try await peer.start(executable: agent.executable, arguments: agent.arguments, directory: workspace.root, environment: AgentSettings.environment)
            let handshake = try await peer.request("initialize", params: ["protocolVersion": 1, "clientCapabilities": ["session": ["configOptions": ["boolean": [:]]]], "clientInfo": ["name": "ccode", "version": "0.1.0"]], timeout: .seconds(20))
            guard handshake["protocolVersion"].int == 1 else { throw ACPError.protocolViolation("This client supports ACP v1.") }
            guard generation == homeDiscoveryGeneration, homeMatches(context, revision: revision) else { throw CancellationError() }
            homeAuthMethods = handshake["authMethods"].array.filter { $0["type"].isNull || $0["type"].string == "agent" }
            if let authentication {
                guard homeAuthMethods.contains(where: { $0["id"].string == authentication }) else { throw ACPError.workspace("Agent did not advertise this authentication method.") }
                _ = try await peer.request("authenticate", params: ["methodId": .string(authentication)], timeout: .seconds(10 * 60))
            }
            let session = try await peer.request("session/new", params: ["cwd": .string(workspace.root), "mcpServers": []], timeout: .seconds(20))
            guard let id = session["sessionId"].optionalString, !id.isEmpty else { throw ACPError.protocolViolation("Agent did not return a session ID.") }
            var catalog = context
            catalog.configOptions = session["configOptions"].array; catalog.modes = session["modes"]; catalog.models = session["models"]
            await peer.close()
            try Task.checkCancellation()
            guard generation == homeDiscoveryGeneration, homeMatches(context, revision: revision) else { throw CancellationError() }
            try await storage.saveAgentCatalog(catalog)
            guard generation == homeDiscoveryGeneration, homeMatches(context, revision: revision), !Task.isCancelled else { return }
            installHomeOptions(catalog.configOptions, modes: catalog.modes, models: catalog.models, agent: agent); homeDiscoveryError = nil; homeAuthMethods = []
        } catch {
            await peer.close()
            if !(error is CancellationError), !Task.isCancelled, generation == homeDiscoveryGeneration, homeMatches(context, revision: revision) { homeDiscoveryError = error.localizedDescription }
        }
    }
    var homeConfigurationOptions: [JSONValue] {
        guard homeConfigurationAgent?.executable == settings.executable, homeConfigurationAgent?.arguments == settings.arguments else { return [] }
        return homeConfigOptions.map { option in
            var displayed = option
            if let value = newSessionDraft.configuration?.values[option["id"].string] { displayed["currentValue"] = value }
            return displayed
        }
    }
    func homeLegacyState(model: Bool) -> JSONValue {
        guard homeConfigOptions.isEmpty, homeConfigurationAgent?.executable == settings.executable, homeConfigurationAgent?.arguments == settings.arguments else { return [:] }
        var state = model ? homeModels : homeModes
        if let id = newSessionDraft.configuration?.legacyValues?[model ? "modelId" : "modeId"] { state[model ? "currentModelId" : "currentModeId"] = .string(id) }
        return state
    }
    func chooseHomeLegacy(model: Bool, id: String) {
        let state = homeLegacyState(model: model)
        guard !startingSession, !discoveringHomeOptions, state[model ? "availableModels" : "availableModes"].array.contains(where: { $0[model ? "modelId" : "id"].string == id }) else { return }
        if newSessionDraft.configuration?.legacyValues == nil { newSessionDraft.configuration?.legacyValues = [:] }
        newSessionDraft.configuration?.legacyValues?[model ? "modelId" : "modeId"] = id
    }
    func chooseHomeConfiguration(id: String, value: JSONValue) {
        guard !startingSession, !discoveringHomeOptions, homeConfigurationAgent?.executable == settings.executable, homeConfigurationAgent?.arguments == settings.arguments, homeConfigOptions.contains(where: { $0["id"].string == id }) else { return }
        if newSessionDraft.configuration == nil { newSessionDraft.configuration = SessionConfiguration(executable: settings.executable, arguments: settings.arguments) }
        newSessionDraft.configuration?.values[id] = value
        newSessionDraft.configuration?.defaultOptionIDs?.remove(id)
    }
    func continueWithCurrentConfiguration(_ chat: ChatSession) {
        guard !chat.busy else { return }
        chat.transcript.pendingConfiguration = nil
        Task { await save(chat) }
    }
    func removeLaunchChoice(_ chat: ChatSession, key: String, legacy: Bool) {
        guard !chat.busy, canDeliver(chat), var configuration = chat.transcript.pendingConfiguration else { return }
        if legacy {
            guard configuration.legacyValues?[key] != nil else { return }
            configuration.legacyValues?.removeValue(forKey: key)
        } else {
            guard configuration.values[key] != nil else { return }
            configuration.values.removeValue(forKey: key)
            configuration.defaultOptionIDs?.remove(key)
        }
        chat.transcript.pendingConfiguration = configuration.values.isEmpty && (configuration.legacyValues ?? [:]).isEmpty ? nil : configuration
        // Removing one rejected choice neither submits the draft nor resets the
        // selected model/mode or another saved launch value.
        Task { await save(chat) }
    }
    func chooseNewSessionProject() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        if !newSessionDraft.projectPath.isEmpty { panel.directoryURL = URL(fileURLWithPath: newSessionDraft.projectPath) }
        if panel.runModal() == .OK, let url = panel.url { Task { await openHome(path: url.path) } }
    }
    func startFromHome() async {
        guard !showNewBranch, !changingBranch, !startingSession, !discoveringHomeOptions, !homeAttachingFiles, !shuttingDown,
              !newSessionDraft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newSessionDraft.attachments?.isEmpty == false else { return }
        guard !newSessionDraft.projectPath.isEmpty else { chooseNewSessionProject(); return }
        startingSession = true
        defer { startingSession = false; homeLaunchTask = nil }
        let draft = newSessionDraft
        let launch = Task { await performHomeLaunch(draft) }
        homeLaunchTask = launch
        await withTaskCancellationHandler { await launch.value } onCancel: { launch.cancel() }
    }
    private func performHomeLaunch(_ draft: NewSessionDraft) async {
        do {
            try await storage.saveNewSessionDraft(draft)
            try Task.checkCancellation()
            guard let id = await create(path: draft.projectPath, worktree: draft.worktree, initialPrompt: draft.text, initialAttachments: draft.attachments ?? [], configuration: draft.configuration, branch: draft.branch, additionalDirectories: draft.additionalDirectories ?? []), let chat = loaded[id] else { return }
            defer { chat.launching = false }
            guard !Task.isCancelled, chat.launching, !chat.closing, !shuttingDown else { return }
            if newSessionDraft == draft {
                var cleared = draft; cleared.text = ""; cleared.attachments = nil
                try await storage.saveNewSessionDraft(cleared)
                guard !Task.isCancelled, chat.launching, !chat.closing, !shuttingDown else { await saveNewSessionDraft(); return }
                if newSessionDraft == draft { newSessionDraft = cleared }
                else { await saveNewSessionDraft() }
            }
            guard !Task.isCancelled, chat.launching, !chat.closing, !shuttingDown else { return }
            chat.launching = false
            startPrompt(chat, text: draft.text.trimmingCharacters(in: .whitespacesAndNewlines), attachments: draft.attachments ?? [])
        } catch { if !(error is CancellationError) { self.error = "Could not start session: \(error.localizedDescription)" } }
    }
    func saveNewSessionDraft() async {
        do { try await storage.saveNewSessionDraft(newSessionDraft) }
        catch { self.error = "Could not save New-session draft: \(error.localizedDescription)" }
    }
    @discardableResult func createHomeBranch(_ name: String) async -> Bool {
        guard !changingBranch, !startingSession, !shuttingDown else { return false }
        let path = newSessionDraft.projectPath, base = newSessionDraft.branch
        changingBranch = true; defer { changingBranch = false; homeBranchTask = nil }
        let operation = Task {
            do {
                try await Repository.createBranch(at: path, name: name, from: base)
                try Task.checkCancellation()
                guard !shuttingDown else { throw CancellationError() }
                if newSessionDraft.projectPath == path, newSessionDraft.branch == base {
                    newSessionDraft.branch = name
                    try await storage.saveNewSessionDraft(newSessionDraft)
                }
                return true
            } catch {
                if !(error is CancellationError) { self.error = "Could not create branch: \(error.localizedDescription)" }
                return false
            }
        }
        homeBranchTask = operation
        return await withTaskCancellationHandler { await operation.value } onCancel: { operation.cancel() }
    }
    func cancelHomeBranch() { homeBranchTask?.cancel(); showNewBranch = false }
    @discardableResult func create(path: String, worktree: Bool, initialPrompt: String? = nil, initialAttachments: [Attachment] = [], configuration: SessionConfiguration? = nil, branch: String? = nil, additionalDirectories: [String] = [], sessionID: UUID = UUID(), select: Bool = true, scheduledOrigin: ScheduledOrigin? = nil) async -> UUID? {
        guard !shuttingDown, !changingBranch else { return nil }
        guard !sessions.contains(where: { $0.id == sessionID }), scheduledOrigin == nil || (scheduledOrigin?.runID == sessionID && configuration != nil) else { return nil }
        let revision = selectionRevision
        let changesBranch = !worktree && branch != nil
        if changesBranch { changingBranch = true }
        defer { if changesBranch { changingBranch = false } }
        var createdChat: ChatSession?
        var createdWorktree: (path: String, branch: String)?
        var savedID: UUID?
        var published = false
        do {
            try Task.checkCancellation()
            _ = try Workspace(root: path, additionalDirectories: additionalDirectories)
            if !worktree, let branch {
                let current = (try? await Repository.run(["symbolic-ref", "--short", "HEAD"], at: path))?.trimmingCharacters(in: .newlines)
                if current != branch {
                    let root = try await Repository.run(["rev-parse", "--show-toplevel"], at: path).trimmingCharacters(in: .newlines)
                    let checkout = try Workspace(root: root).root
                    for chat in Array(loaded.values) where chat.busy || chat.hasLiveAgentWork {
                        for directory in chat.workspace.roots {
                            let otherRoot = try? await Repository.run(["rev-parse", "--show-toplevel"], at: directory).trimmingCharacters(in: .newlines)
                            let other = otherRoot.flatMap { try? Workspace(root: $0).root }
                            if other == checkout || checkout == directory || checkout.hasPrefix(directory == "/" ? "/" : directory + "/") {
                                throw ACPError.workspace("Another session is using this checkout. Use a worktree or wait for it to finish before changing branches.")
                            }
                        }
                    }
                }
                try Task.checkCancellation()
                try await Repository.switchBranch(at: path, branch: branch)
            }
            let name = "session-\(UUID().uuidString.prefix(8).lowercased())"
            let folder = worktree ? try await Repository.createWorktree(at: path, name: name, branch: branch, storageDirectory: worktreeDirectory) : path
            if worktree { createdWorktree = (folder, "ccode/" + name) }
            try Task.checkCancellation()
            guard !shuttingDown else { throw CancellationError() }
            let workspace = try Workspace(root: folder, additionalDirectories: additionalDirectories)
            var info = SessionInfo(id: sessionID, projectPath: folder, title: scheduledOrigin?.taskName ?? "New session")
            info.scheduledOrigin = scheduledOrigin
            if scheduledOrigin != nil, let configuration { info.agentExecutable = configuration.executable; info.agentArguments = configuration.arguments }
            if worktree { info.worktreeSourcePath = try Workspace(root: path).root }
            info.additionalDirectories = Array(workspace.roots.dropFirst())
            var transcript = SessionTranscript(); transcript.draftText = initialPrompt; transcript.pendingConfiguration = configuration
            transcript.draftAttachments = initialAttachments.isEmpty ? nil : initialAttachments
            let chat = try ChatSession(id: info.id, path: folder, transcript: transcript, additionalDirectories: info.additionalDirectories ?? [], environment: info.environment, sshExecutable: sshExecutable)
            chat.launching = initialPrompt != nil; createdChat = chat
            savedID = info.id
            try await storage.save(transcript, id: info.id)
            try Task.checkCancellation()
            guard !shuttingDown else { throw CancellationError() }
            sessions.insert(info, at: 0); loaded[info.id] = chat; observeAttention(chat)
            published = true
            if select, selectionRevision == revision { selectionRevision += 1; recordVisit(info.id); selectedID = info.id; pane = nil }
            try await storage.saveIndex(sessions)
            await refreshWorkspace(chat)
            return info.id
        } catch {
            createdChat?.launching = false
            var preservation: String?
            if !published {
                if let savedID { try? await storage.discardUnpublished(savedID) }
                if let createdWorktree {
                    let cleanupError = await Task.detached { () -> String? in
                        do { try await Repository.removeWorktree(at: path, path: createdWorktree.path, expectedBranch: createdWorktree.branch); return nil }
                        catch { return error.localizedDescription }
                    }.value
                    if let cleanupError { preservation = "Worktree preserved at \(createdWorktree.path): \(cleanupError)" }
                }
            }
            if let preservation { self.error = preservation + (error is CancellationError ? "" : "\n" + error.localizedDescription) }
            else if !(error is CancellationError) { self.error = error.localizedDescription }
            return nil
        }
    }
    private func sessionParameters(_ chat: ChatSession, directory: String, sessionID: String? = nil) throws -> JSONValue {
        var params: JSONValue = ["cwd": .string(directory), "mcpServers": []]
        if chat.transcript.browserToolsEnabled == true {
            guard let endpoint = chat.browserWorkspace.endpoint else { throw ACPError.workspace("Browser tool server is not connected.") }
            params["mcpServers"] = [try AgentSettings.browserServerParameters(handshake: chat.handshake, endpoint: endpoint)]
        }
        if chat.transcript.sessionToolsEnabled == true {
            guard let endpoint=chat.sessionToolEndpoint else { throw ACPError.workspace("App session tools are not connected.") }
            var servers=params["mcpServers"].array
            var parameters=try AgentSettings.browserServerParameters(handshake:chat.handshake,endpoint:endpoint)
            parameters["name"]="ccode-sessions";servers.append(parameters);params["mcpServers"] = .array(servers)
        }
        if chat.transcript.computerToolsEnabled == true || chat.transcript.simulatorToolsEnabled == true {
            guard let endpoint=chat.nativeToolEndpoint else { throw ACPError.workspace("Native tool server is not connected.") }
            var server=try AgentSettings.browserServerParameters(handshake:chat.handshake,endpoint:endpoint);server["name"]="ccode-native"
            params["mcpServers"] = .array(params["mcpServers"].array + [server])
        }
        if let sessionID { params["sessionId"] = .string(sessionID) }
        let additional = Array(chat.workspace.roots.dropFirst())
        if !additional.isEmpty {
            guard case .object = chat.handshake["agentCapabilities"]["sessionCapabilities"]["additionalDirectories"] else { throw ACPError.workspace("This agent does not support additional folders. Use an agent that advertises additional directories, or start a new session with only the project folder.") }
            params["additionalDirectories"] = .array(additional.map(JSONValue.string))
        }
        return params
    }
    func setBrowserTools(_ chat: ChatSession, enabled: Bool) async throws {
        guard canDeliver(chat), !chat.busy, !chat.hasLiveAgentWork, chat.pendingPrompts.isEmpty, chat.pendingSettings.isEmpty else {
            throw ACPError.workspace("Finish agent work and queued messages before changing browser tools.")
        }
        guard !enabled || chat.workspace.environment.isLocal else { throw ACPError.workspace("Mac browser tools require a local session. Use MCP configured on the remote host for SSH.") }
        if enabled, chat.connection != nil, !chat.handshake["agentCapabilities"]["mcpCapabilities"]["http"].bool {
            throw ACPError.workspace("This agent does not support HTTP MCP browser tools.")
        }
        let reconnect = chat.connection != nil
        chat.configuring = true
        defer { chat.configuring = false }
        chat.transcript.browserToolsEnabled = enabled ? true : nil
        await save(chat)
        if reconnect { await disconnect(chat) }
        else if !enabled { await chat.browserWorkspace.disconnectTools() }
        if reconnect { try await connect(chat) }
    }
    func addHomeFolders(_ paths: [String]) {
        do {
            let workspace = try Workspace(root: newSessionDraft.projectPath, additionalDirectories: (newSessionDraft.additionalDirectories ?? []) + paths)
            newSessionDraft.additionalDirectories = Array(workspace.roots.dropFirst())
            Task { await saveNewSessionDraft() }
        } catch { self.error = error.localizedDescription }
    }
    func chooseAdditionalSessionFolders() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.title = "Add folder to session"; panel.prompt = "Add"
        if !newSessionDraft.projectPath.isEmpty { panel.directoryURL = URL(fileURLWithPath: newSessionDraft.projectPath) }
        if panel.runModal() == .OK { addHomeFolders(panel.urls.map(\.path)) }
    }
    func removeHomeFolder(_ path: String) {
        newSessionDraft.additionalDirectories?.removeAll { $0 == path }
        Task { await saveNewSessionDraft() }
    }
    func canFork(_ chat: ChatSession, at itemID: UUID? = nil) -> Bool {
        guard !changingBranch, !chat.busy, !chat.hasLiveAgentWork, chat.transcript.remoteID != nil,
              chat.handshake["agentCapabilities"].isNull || supportsFork(chat) else { return false }
        guard let itemID else { return true }
        guard (chat.transcript.subagents ?? []).isEmpty, (chat.transcript.asyncTasks ?? []).isEmpty else { return false }
        return forkBoundary(chat, id: itemID) != nil && (chat.handshake["agentCapabilities"].isNull || supportsMessageFork(chat))
    }
    private func forkBoundary(_ chat: ChatSession, id: UUID) -> Int? {
        chat.transcript.items.firstIndex { $0.id == id && $0.kind == "assistant" && !($0.messageID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    func supportsMessageFork(_ chat: ChatSession) -> Bool {
        // ponytail: this provider extension is verified in 0.84.0; verify wire/context behavior before allowing other versions.
        chat.handshake["agentInfo"]["name"].string == "@agentclientprotocol/claude-agent-acp" && chat.handshake["agentInfo"]["version"].string == "0.84.0"
    }
    private func supportsFork(_ chat: ChatSession) -> Bool {
        let capabilities = chat.handshake["agentCapabilities"]
        guard case .object = capabilities["sessionCapabilities"]["fork"] else { return false }
        if case .object = capabilities["sessionCapabilities"]["resume"] { return true }
        return capabilities["loadSession"].bool
    }
    private enum ContinuationPoint { case latest, after(UUID), before(UUID) }
    private func revisionPrompt(_ chat: ChatSession, at itemID: UUID) -> Int? {
        guard let index = chat.transcript.items.firstIndex(where: { $0.id == itemID }) else { return nil }
        let item = chat.transcript.items[index]
        let promptIndex: Int
        if item.kind == "assistant" {
            guard let previous = chat.transcript.items[..<index].lastIndex(where: { $0.kind == "user" }) else { return nil }
            promptIndex = previous
        } else if item.kind == "user" { promptIndex = index }
        else { return nil }
        let prompt = chat.transcript.items[promptIndex]
        // Imported/older prompts can join a running turn; an assistant row alone is not a checkpoint.
        guard prompt.peerMessage == nil, prompt.startedSession != nil, !prompt.text.isEmpty || !(prompt.promptAttachments ?? []).isEmpty else { return nil }
        // Provider links are not permission to read files. Only our typed snapshots can be resent.
        if !prompt.blocks.isEmpty {
            guard let attachments = prompt.promptAttachments, attachments.count == prompt.blocks.count,
                  zip(attachments, prompt.blocks).allSatisfy({ attachment, block in
                      block["type"].string == "resource_link" && block["uri"].string == storage.attachmentURL(attachment).absoluteString
                  }) else { return nil }
        }
        return promptIndex
    }
    private func continuationBoundary(_ chat: ChatSession, point: ContinuationPoint) throws -> (count: Int?, messageID: String?) {
        switch point {
        case .latest: return (nil, nil)
        case .after(let id):
            guard let index = forkBoundary(chat, id: id) else { throw ACPError.workspace("The selected message is no longer in this session.") }
            return (index + 1, chat.transcript.items[index].messageID)
        case .before(let id):
            guard let index = revisionPrompt(chat, at: id), chat.transcript.items[index].id == id else { throw ACPError.workspace("This prompt cannot be edited or retried without losing context or attachments.") }
            let preceding = chat.transcript.items[..<index].lastIndex { $0.kind != "notice" }
            guard let preceding else {
                guard chat.transcript.items[index].startedSession == true else { throw ACPError.workspace("The first visible prompt may have earlier agent context. Its history boundary is unavailable.") }
                return (0, nil)
            }
            guard let boundary = forkBoundary(chat, id: chat.transcript.items[preceding].id) else { throw ACPError.workspace("The preceding turn has no complete assistant boundary. It cannot safely be edited or retried.") }
            return (index, chat.transcript.items[boundary].messageID)
        }
    }
    func canRevise(_ chat: ChatSession, at itemID: UUID) -> Bool {
        guard !changingBranch, !shuttingDown, !chat.busy, !chat.hasLiveAgentWork, let index = revisionPrompt(chat, at: itemID),
              let boundary = try? continuationBoundary(chat, point: .before(chat.transcript.items[index].id)) else { return false }
        if boundary.count != 0, !(chat.transcript.subagents ?? []).isEmpty || !(chat.transcript.asyncTasks ?? []).isEmpty { return false }
        return boundary.count == 0 || canFork(chat) && (chat.handshake["agentCapabilities"].isNull || supportsMessageFork(chat))
    }
    @discardableResult func editMessage(_ chat: ChatSession, at itemID: UUID) async throws -> UUID {
        guard canRevise(chat, at: itemID), let index = revisionPrompt(chat, at: itemID), chat.transcript.items[index].id == itemID else { throw ACPError.workspace("This prompt cannot safely be edited with the current agent.") }
        let item = chat.transcript.items[index]
        return try await createContinuation(chat, point: .before(item.id), originKind: .edit, sourceItemID: itemID, draft: item.text, attachments: item.promptAttachments ?? [], suffix: " (edit)")
    }
    @discardableResult func retryResponse(_ chat: ChatSession, at itemID: UUID) async throws -> UUID {
        guard canRevise(chat, at: itemID), let response = chat.transcript.items.first(where: { $0.id == itemID && $0.kind == "assistant" }), let index = revisionPrompt(chat, at: response.id) else { throw ACPError.workspace("This response cannot safely be retried with the current agent.") }
        let item = chat.transcript.items[index]
        return try await createContinuation(chat, point: .before(item.id), originKind: .retry, sourceItemID: itemID, draft: item.text, attachments: item.promptAttachments ?? [], suffix: " (retry)", sendDraft: true)
    }
    @discardableResult func fork(_ chat: ChatSession, at itemID: UUID? = nil) async throws -> UUID {
        try await createContinuation(chat, point: itemID.map(ContinuationPoint.after) ?? .latest, originKind: .fork, sourceItemID: itemID)
    }
    private func createContinuation(_ chat: ChatSession, point: ContinuationPoint, originKind: ConversationOrigin.Kind, sourceItemID: UUID?, draft: String? = nil, attachments: [Attachment] = [], suffix: String = " (fork)", sendDraft: Bool = false) async throws -> UUID {
        guard !changingBranch, !shuttingDown, !chat.busy, !chat.hasLiveAgentWork, sessions.contains(where: { $0.id == chat.id && !$0.archived }) else { throw ACPError.workspace("Wait for this session to finish before continuing it independently.") }
        let initialBoundary = try continuationBoundary(chat, point: point)
        if initialBoundary.count != nil, initialBoundary.count != 0, !(chat.transcript.subagents ?? []).isEmpty || !(chat.transcript.asyncTasks ?? []).isEmpty {
            throw ACPError.workspace("This selected boundary has independent subagent history whose cutoff is not captured. Whole-session fork remains available.")
        }
        guard initialBoundary.count == 0 || chat.transcript.remoteID != nil else { throw ACPError.workspace("Session has no agent history to fork.") }
        let revision = selectionRevision
        chat.forking = true
        var ownsFork = true
        defer { if ownsFork { chat.forking = false } }
        if initialBoundary.count != 0 { try await connect(chat) }
        guard let source = sessions.first(where: { $0.id == chat.id && !$0.archived }) else { throw CancellationError() }
        let generation = chat.connectionGeneration
        let peer = chat.connection
        let boundary = try continuationBoundary(chat, point: point)
        let configuration = draft == nil ? nil : confirmedConfiguration(chat)
        var transcript = chat.transcript
        if boundary.count == 0 {
            transcript.remoteID = nil
        } else {
            guard supportsFork(chat) else { throw ACPError.workspace("This agent must support session fork and load or resume to continue an independent chat.") }
            guard let peer, let remoteID = chat.transcript.remoteID else { throw ACPError.workspace("Session is not connected.") }
            var params = try sessionParameters(chat, directory: source.projectPath, sessionID: remoteID)
            // A new fork must receive its own tab/server owner when it connects.
            params["mcpServers"] = []
            if let messageID = boundary.messageID {
                guard supportsMessageFork(chat) else { throw ACPError.workspace("This agent does not support a selected history boundary. Whole-session fork remains available.") }
                params["_meta"] = ["jetbrains": ["air": ["fork": ["version": 1, "messageId": .string(messageID)]]]]
            }
            let result = try await peer.request("session/fork", params: params)
            guard chat.connectionGeneration == generation, !Task.isCancelled else { throw CancellationError() }
            guard let forkedID = result["sessionId"].optionalString, !forkedID.isEmpty, forkedID != remoteID else { throw ACPError.protocolViolation("Agent did not return a new forked session ID.") }
            transcript.remoteID = forkedID; transcript.configure(result)
        }
        if let count = boundary.count { transcript.items = Array(transcript.items.prefix(count)); transcript.plan = [] }
        if boundary.count == 0 { transcript.subagents = nil; transcript.asyncTasks = nil }
        else if let children = transcript.subagents {
            for index in children.indices where children[index].parentID == chat.transcript.remoteID {
                transcript.subagents?[index].parentID = transcript.remoteID ?? children[index].parentID
            }
        }
        transcript.rebaseAsyncTasks(from: chat.transcript.remoteID, to: transcript.remoteID)
        transcript.beginTurn()
        transcript.remoteUnprompted = nil
        transcript.draftText = draft; transcript.draftAttachments = attachments.isEmpty ? nil : attachments; transcript.editorDrafts = nil; transcript.pendingConfiguration = configuration; transcript.usage = [:]
        transcript.sessionToolsEnabled = nil
        transcript.pendingPrompts = nil; transcript.deliveryPaused = nil
        transcript.pendingSettings = nil; transcript.settingsPaused = nil
        var info = SessionInfo(projectPath: source.projectPath, title: source.title + suffix)
        info.origin = ConversationOrigin(kind: originKind, sourceSessionID: source.id, sourceRemoteID: chat.transcript.remoteID, sourceItemID: sourceItemID, boundaryMessageID: boundary.messageID, startsFresh: boundary.count == 0)
        info.executionEnvironment = source.executionEnvironment
        info.worktreeSourcePath = source.worktreeSourcePath
        info.additionalDirectories = source.additionalDirectories
        info.agentExecutable = source.agentExecutable; info.agentArguments = source.agentArguments
        let branch = try ChatSession(id: info.id, path: info.projectPath, transcript: transcript, additionalDirectories: info.additionalDirectories ?? [], environment: info.environment, sshExecutable: sshExecutable)
        branch.handshake = chat.handshake
        try await storage.save(transcript, id: info.id)
        guard chat.connectionGeneration == generation, !Task.isCancelled, !chat.closing, chat.connection === peer, sessions.contains(where: { $0.id == chat.id && !$0.archived }) else {
            try? await storage.discardUnpublished(info.id)
            throw CancellationError()
        }
        sessions.insert(info, at: 0); loaded[info.id] = branch; observeAttention(branch)
        ownsFork = false; chat.forking = false
        // Reserve retry's prompt before selection awaits can evict or expose an idle branch.
        if sendDraft { send(branch) }
        try await storage.saveIndex(sessions)
        if selectedID == chat.id, selectionRevision == revision, !branch.closing, sessions.contains(where: { $0.id == info.id && !$0.archived }) { await select(info.id) }
        return info.id
    }
    func refreshWorkspace(_ chat: ChatSession) async {
        let operation = UUID(); chat.workspaceRefreshID = operation
        let directory = chat.workspaceDirectory
        async let status = chat.workspace.repository.status(at: directory)
        async let files = chat.workspace.files()
        let repository = (try? await status) ?? RepositoryStatus()
        let catalog = (try? await files) ?? []
        guard !Task.isCancelled, !chat.closing, chat.workspaceRefreshID == operation, chat.workspaceDirectory == directory else { return }
        chat.repository = repository; chat.files = catalog
        chat.workspaceRevision = UUID()
        refreshChangeStatistics(chat)
    }
    func rename(_ id: UUID, title: String) {
        guard !sessionToolMutations.contains(id), let index = sessions.firstIndex(where: { $0.id == id }), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sessions[index].title = title; persistIndex()
    }
    func togglePin(_ id: UUID) { if let i = sessions.firstIndex(where: { $0.id == id }) { sessions[i].pinned.toggle(); persistIndex() } }
    func archive(_ id: UUID, setArchived: Bool? = nil, persist: Bool = true) async {
        guard (!persist || !sessionToolMutations.contains(id)), sessions.contains(where: { $0.id == id }), loaded[id]?.closing != true else { return }
        let wasSelected = selectedID == id
        dictation.cancel(for: .chat(id)); dictation.cancel(for: .sideQuestion(id))
        for pane in paneLayout.detachedWorkspacePanes.filter({ $0.sessionID == id }) { chatWindows?.releaseWindow(for:pane.id);paneLayout.closeWorkspace(pane.id) }
        if let pane = paneLayout.allPanes.first(where: { $0.sessionID == id }) {
            nativeReadTasks.removeValue(forKey: pane.id)?.cancel()
            paneLoadGenerations.removeValue(forKey: pane.id); loadingSessions.removeValue(forKey: pane.id)
            paneLayout.close(pane.id); selectionRevision += 1
        }
        if let chat = loaded[id] { await closeTerminals(chat); cancelAttachmentImports(chat); await chat.attachmentTask?.value; await disconnect(chat); await save(chat); loaded.removeValue(forKey: id) }
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].archived = setArchived ?? !sessions[i].archived; sessions[i].attention = nil; attentionNotifications?.clear(sessionID: id)
        runtimeActivities.removeValue(forKey: id); rebuildSidebar(); if persist { persistIndex() }
        if wasSelected, selectedID == nil, let next = visibleSessions.first { await select(next.id) }
    }
    func connect(_ chat: ChatSession, authentication: String? = nil, reloadHistory: Bool = false) async throws {
        guard !checkpointRestorationBlocks(chat) else { throw ACPError.workspace("Wait for file restoration to finish.") }
        guard !changingBranch else { throw ACPError.workspace("Wait for the branch change to finish.") }
        guard !chat.closing, !shuttingDown else { throw ACPError.workspace("This session is closing.") }
        guard let info = sessions.first(where: { $0.id == chat.id }) else { throw ACPError.workspace("Session is missing.") }
        guard info.environment == chat.workspace.environment else { throw ACPError.workspace("The execution host changed. Reopen this session before connecting.") }
        if !reloadHistory, authentication == nil, chat.connection != nil, [.ready, .running].contains(chat.state) { return }
        if chat.connection != nil, chat.state == .connecting { throw ACPError.workspace("Agent connection is already being established.") }
        if chat.transcript.remoteUnprompted == true, chat.transcript.items.isEmpty { resetUnpromptedSession(chat) }
        let creatingSession = chat.transcript.remoteID == nil
        let executable = info.agentExecutable ?? settings.executable
        let arguments = info.agentArguments ?? settings.arguments
        // session/load may reset settings on a fresh process. Restore only the
        // confirmed catalog owned by this exact saved agent and session.
        if !creatingSession, chat.transcript.pendingConfiguration == nil,
           info.agentExecutable == executable, info.agentArguments == arguments,
           info.remoteSessionID == chat.transcript.remoteID,
           !chat.transcript.configOptions.isEmpty || !chat.transcript.models["currentModelId"].string.isEmpty || !chat.transcript.modes["currentModeId"].string.isEmpty {
            chat.transcript.pendingConfiguration = confirmedConfiguration(chat)
        }
        let initialConfiguration = chat.transcript.pendingConfiguration
        guard !executable.isEmpty, !executable.contains("\0"), !info.environment.isLocal || executable.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: executable) else { showSettings = true; throw ACPError.workspace("Choose an installed ACP executable in Settings.") }
        chat.state = .connecting; chat.lastError = nil
        let generation = UUID(); chat.connectionGeneration = generation; chat.setupGeneration = generation
        await stopNativeServer(chat)
        await stopAppSessionServer(chat)
        guard chat.connectionGeneration == generation,!shuttingDown,!chat.closing else { throw CancellationError() }
        chat.childOwners.removeAll(); chat.transcript.disconnectSubagents(); chat.stoppingSubagents.removeAll()
        chat.asyncTaskOwners.removeAll(); chat.transcript.disconnectAsyncTasks(); chat.stoppingAsyncTasks.removeAll()
        if let stale = chat.connection {
            await stopNativeServer(chat)
        await stopAppSessionServer(chat)
            cancelApprovals(chat); await stale.close()
            guard chat.connectionGeneration == generation else { throw CancellationError() }
            chat.connection = nil
        }
        guard chat.connectionGeneration == generation else { throw CancellationError() }
        guard !chat.closing, !shuttingDown, loaded[chat.id] === chat else { chat.state = .idle; throw CancellationError() }
        let peer = ACPConnection(onUpdates: { [weak self, weak chat] batch in
            guard let self, let chat else { return }; await self.receive(batch, chat: chat, generation: generation)
        }, onRequest: { [weak self, weak chat] method, params in
            guard let self, let chat else { throw CancellationError() }
            return try await self.callback(method, params: params, chat: chat, generation: generation)
        }, onNotification: { [weak self, weak chat] method, params in
            guard let self, let chat else { return }
            await self.notification(method, params: params, chat: chat, generation: generation)
        }, onDisconnect: { [weak self, weak chat] reason in
            guard let self, let chat else { return }; await self.disconnected(chat, reason: reason, generation: generation)
        })
        chat.connection = peer
        do {
            let launch = info.environment.isLocal ? AgentSettings.nativeSubagentLaunch(executable: executable, arguments: arguments) : (executable: executable, arguments: arguments)
            try await peer.start(environment: info.environment, executable: launch.executable, arguments: launch.arguments, directory: info.projectPath, localEnvironment: AgentSettings.environment, sshExecutable: chat.workspace.sshExecutable)
            var checkpointCapabilities: JSONValue = ["nativeSubagents": true, "asyncTasks": true, "nativeSubagentStop": true, "fileCheckpoints": true, "configurationManagement": true, "sideQuestions": true]
            if info.environment.isLocal, let recovery = try? await storage.prepareCheckpointRecoveryDirectory() { checkpointCapabilities["fileCheckpointRecoveryDirectory"] = .string(recovery.path) }
            var clientCapabilities: JSONValue = ["fs": ["readTextFile": true, "writeTextFile": true], "terminal": true, "elicitation": ["form": [:], "url": [:]], "session": ["configOptions": ["boolean": [:]]]]
            if info.environment.isLocal { clientCapabilities["subagents"] = [:]; clientCapabilities["_meta"] = ["ccode": checkpointCapabilities] }
            if !info.environment.isLocal, chat.transcript.browserToolsEnabled == true || chat.transcript.sessionToolsEnabled == true || chat.transcript.computerToolsEnabled == true || chat.transcript.simulatorToolsEnabled == true { throw ACPError.workspace("Disconnect Mac browser and app-session tools before connecting this SSH session.") }
            let handshake = try await peer.request("initialize", params: ["protocolVersion": 1, "clientCapabilities": clientCapabilities, "clientInfo": ["name": "ccode", "title": "ccode", "version": "0.1.0"]])
            guard chat.connectionGeneration == generation, !shuttingDown, !chat.closing else { throw CancellationError() }
            guard handshake["protocolVersion"].int == 1 else { throw ACPError.protocolViolation("This client supports ACP v1; the agent returned \(handshake["protocolVersion"].int).") }
            chat.handshake = handshake
            if chat.transcript.browserToolsEnabled == true {
                guard handshake["agentCapabilities"]["mcpCapabilities"]["http"].bool else { throw ACPError.workspace("This agent does not support HTTP MCP browser tools. Disconnect browser tools to continue.") }
                _ = try await chat.browserWorkspace.prepareTools()
                guard chat.connectionGeneration == generation, !shuttingDown, !chat.closing else { throw CancellationError() }
            }
            if let authentication {
                guard handshake["authMethods"].array.contains(where: { $0["id"].string == authentication && ($0["type"].isNull || $0["type"].string == "agent") }) else { throw ACPError.workspace("Agent did not advertise this authentication method.") }
                _ = try await peer.request("authenticate", params: ["methodId": .string(authentication)], timeout: .seconds(10 * 60))
            }
            if chat.transcript.sessionToolsEnabled == true {
                try await prepareAppSessionServer(chat,generation:generation)
                guard chat.connectionGeneration == generation,!chat.closing,!shuttingDown else { await stopNativeServer(chat,generation:generation); await stopAppSessionServer(chat,generation:generation);throw CancellationError() }
            }
            if chat.transcript.computerToolsEnabled == true || chat.transcript.simulatorToolsEnabled == true { try await prepareNativeServer(chat,generation:generation) }
            let params = try sessionParameters(chat, directory: info.projectPath, sessionID: chat.transcript.remoteID)
            let result: JSONValue
            if let remoteID = chat.transcript.remoteID {
                let capabilities = handshake["agentCapabilities"]
                if !reloadHistory, !capabilities["sessionCapabilities"]["resume"].isNull {
                    result = try await peer.request("session/resume", params: params)
                } else if capabilities["loadSession"].bool {
                    chat.loadingHistory = true; chat.historyReplay = SessionTranscript(remoteID: remoteID)
                    do { result = try await peer.request("session/load", params: params) }
                    catch { if chat.connectionGeneration == generation { chat.historyReplay = nil; chat.loadingHistory = false }; throw error }
                    guard chat.connectionGeneration == generation else { throw CancellationError() }
                    // 0.84.0 infers child completion from a launch acknowledgement
                    // and announces even rejected launches. Fresh recognized SDK
                    // metadata supplies cancellation, actual child existence and
                    // background Bash launches not announced during replay.
                    // Read after replay, then re-read the buffered value so updates
                    // arriving during disk IO cannot be discarded.
                    if info.environment.isLocal, supportsMessageFork(chat) {
                        let native = try? await storage.loadClaudeTranscript(sessionID: remoteID, cwd: info.projectPath)
                        guard chat.connectionGeneration == generation, !shuttingDown, !chat.closing else { throw CancellationError() }
                        if var native, !chat.hasPendingDecisions {
                            native.mergeClaudeHistoricalTasks(from: chat.transcript)
                            if chat.historyReplay?.reconcileClaudeDelegatedReplay(with: native) == true {
                                chat.childOwners.formIntersection(Set((chat.historyReplay?.subagents ?? []).map(\.id)))
                            }
                            _ = chat.historyReplay?.restoreClaudeAsyncReplay(with: native)
                        }
                    }
                    if var replay = chat.historyReplay, !replay.items.isEmpty || !(replay.subagents ?? []).isEmpty || !(replay.asyncTasks ?? []).isEmpty {
                        replay.workspacePane = chat.transcript.workspacePane
                        replay.restoreToolInterruptions(from: chat.transcript)
                        replay.pendingConfiguration = chat.transcript.pendingConfiguration
                        replay.pendingPrompts = chat.transcript.pendingPrompts
                        replay.deliveryPaused = chat.transcript.deliveryPaused
                        replay.pendingSettings = chat.transcript.pendingSettings
                        replay.settingsPaused = chat.transcript.settingsPaused
                        replay.failure = chat.transcript.failure
                        replay.fileRestorations = chat.transcript.fileRestorations
                        replay.discards = chat.transcript.discards
                        replay.workspaceDirectory = chat.transcript.workspaceDirectory
                        replay.selectedEditorFile = chat.transcript.selectedEditorFile
                        replay.editorFolder = chat.transcript.editorFolder
                        replay.reviewComments = chat.transcript.reviewComments
                        replay.codeReview = chat.transcript.codeReview
                        replay.pullRequest = chat.transcript.pullRequest
                        replay.pullRequestOperation = chat.transcript.pullRequestOperation
                        replay.pullRequestAutoFix = chat.transcript.pullRequestAutoFix
                        replay.browserToolsEnabled = chat.transcript.browserToolsEnabled
                        replay.computerToolsEnabled = chat.transcript.computerToolsEnabled
                        replay.simulatorToolsEnabled = chat.transcript.simulatorToolsEnabled
                        replay.sessionToolsEnabled = chat.transcript.sessionToolsEnabled
                        replay.previewLaunch = chat.transcript.previewLaunch
                        if replay.subagents == nil { replay.subagents = chat.transcript.subagents }
                        if replay.asyncTasks == nil { replay.asyncTasks = chat.transcript.asyncTasks }
                        chat.transcript = replay
                    }
                    chat.historyReplay = nil
                    chat.transcript.historyUpdatedAt = info.agentUpdatedAt ?? Date()
                    chat.loadingHistory = false
                } else { throw ACPError.workspace("This agent cannot resume this session. Create a new session to keep the saved history intact.") }
            } else {
                result = try await peer.request("session/new", params: params)
            }
            guard chat.connectionGeneration == generation, !shuttingDown, !chat.closing else { throw CancellationError() }
            chat.transcript.configure(result)
            if creatingSession { chat.transcript.remoteUnprompted = true }
            guard chat.transcript.remoteID != nil else { throw ACPError.protocolViolation("Agent did not return a session ID.") }
            let buffered = chat.pendingSessionEvents; chat.pendingSessionEvents.removeAll(); receive(buffered, chat: chat, generation: generation)
            if let i = sessions.firstIndex(where: { $0.id == chat.id }) {
                var info = sessions[i]; info.agentExecutable = executable; info.agentArguments = arguments; info.remoteSessionID = chat.transcript.remoteID
                if info != sessions[i] { sessions[i] = info }
            }
            if let configuration = chat.transcript.pendingConfiguration {
                guard configuration.executable == executable, configuration.arguments == arguments else { throw ACPError.workspace("Launch choices belong to a different agent. Continue with current agent settings to proceed.") }
                let legacy = configuration.legacyValues ?? [:]
                guard legacy.keys.allSatisfy({ ["modelId", "modeId"].contains($0) }) else { throw ACPError.workspace("Unknown saved agent choice. Continue with current agent settings to proceed.") }
                for key in ["modelId", "modeId"] {
                    if let id = legacy[key] {
                        try Task.checkCancellation()
                        guard !chat.closing else { throw CancellationError() }
                        try await applyLegacy(chat, key: key, id: id)
                        chat.transcript.pendingConfiguration?.legacyValues?.removeValue(forKey: key)
                        await save(chat)
                    }
                }
                let offered = Set(chat.transcript.configOptions.map { $0["id"].string })
                let ids = configuration.values.keys.sorted { a, b in
                    let modelA = chat.transcript.configOptions.first { $0["id"].string == a }?["category"].string == "model"
                    let modelB = chat.transcript.configOptions.first { $0["id"].string == b }?["category"].string == "model"
                    return modelA != modelB ? modelA : a < b
                }
                for id in ids {
                    try Task.checkCancellation()
                    guard !chat.closing else { throw CancellationError() }
                    // A model setter can remove an untouched default (for example Fast mode).
                    // Explicit choices and options missing from the initial catalog still fail.
                    if !(offered.contains(id) && configuration.defaultOptionIDs?.contains(id) == true && !chat.transcript.configOptions.contains(where: { $0["id"].string == id })) {
                        try await applyConfiguration(chat, id: id, value: configuration.values[id]!)
                    }
                    chat.transcript.pendingConfiguration?.values.removeValue(forKey: id)
                    chat.transcript.pendingConfiguration?.defaultOptionIDs?.remove(id)
                    await save(chat)
                }
                chat.transcript.pendingConfiguration = nil
            }
            chat.state = .ready
            await save(chat)
        } catch {
            await peer.close()
            if chat.connectionGeneration == generation {
                await stopNativeServer(chat,generation:generation); await stopAppSessionServer(chat,generation:generation)
                await chat.browserWorkspace.disconnectTools()
                chat.connection = nil; chat.state = .failed; recordFailure(chat, error: error)
            }
            if !creatingSession, chat.setupGeneration == generation, let initialConfiguration {
                // Successful setters on the closed peer are not durable. A
                // subsequent recovery needs the entire saved selection again.
                chat.transcript.pendingConfiguration = initialConfiguration
                await save(chat)
            }
            if creatingSession, chat.setupGeneration == generation {
                // Stop invalidates callbacks, but failed first setup still needs rollback.
                // An agent may not persist a new session until its first prompt.
                chat.transcript.remoteID = nil; chat.transcript.remoteUnprompted = nil
                chat.transcript.pendingConfiguration = initialConfiguration
                if let index = sessions.firstIndex(where: { $0.id == chat.id }) { sessions[index].remoteSessionID = nil }
                await save(chat)
            }
            throw error
        }
    }

    func confirmedConfiguration(_ chat: ChatSession) -> SessionConfiguration? {
        guard let info = sessions.first(where: { $0.id == chat.id }) else { return nil }
        var choices = SessionConfiguration(executable: info.agentExecutable ?? settings.executable, arguments: info.agentArguments ?? settings.arguments,
                values: chat.transcript.configOptions.reduce(into: [:]) { values, option in
                    if !option["id"].string.isEmpty, !option["currentValue"].isNull { values[option["id"].string] = option["currentValue"] }
                })
        if chat.transcript.configOptions.isEmpty {
            let legacy = [("modeId", chat.transcript.modes["currentModeId"]), ("modelId", chat.transcript.models["currentModelId"])]
            choices.legacyValues = legacy.reduce(into: [:]) { values, option in if !option.1.string.isEmpty { values[option.0] = option.1.string } }
        }
        if let pending = chat.transcript.pendingConfiguration {
            guard pending.executable == choices.executable, pending.arguments == choices.arguments else { return pending }
            choices.values.merge(pending.values) { _, requested in requested }
            choices.defaultOptionIDs = pending.defaultOptionIDs
            choices.legacyValues = (choices.legacyValues ?? [:]).merging(pending.legacyValues ?? [:]) { _, requested in requested }
        }
        return choices
    }
    private func resetUnpromptedSession(_ chat: ChatSession, configuration: SessionConfiguration? = nil) {
        guard let index = sessions.firstIndex(where: { $0.id == chat.id }) else { return }
        chat.transcript.pendingConfiguration = configuration ?? confirmedConfiguration(chat)
        chat.transcript.remoteID = nil; chat.transcript.remoteUnprompted = nil
        sessions[index].remoteSessionID = nil
    }

    func send(_ chat: ChatSession, text override: String? = nil, policy: DeliveryPolicy? = nil) {
        guard discardPreviewRequest == nil, discardHistoryRequest == nil, pullRequestDraftRequest == nil, pullRequestMergeRequest == nil, pullRequestLogsRequest == nil, !workspaceBranchEditing else { return }
        let text = (override ?? chat.draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard canDeliver(chat), !chat.attachingFiles, !text.isEmpty || !chat.attachments.isEmpty else { return }
        if override == nil, text.split(whereSeparator: { $0.isWhitespace }).first == "/btw" {
            guard chat.attachments.isEmpty, chat.sideQuestionTask == nil else { chat.sideQuestionError="Finish the current side question and remove attachments before using /btw.";chat.showSideQuestion=true;return }
            chat.showSideQuestion=true;chat.sideQuestionDraft=String(text.dropFirst(4)).trimmingCharacters(in:.whitespacesAndNewlines)
            chat.draft=""
            if !chat.sideQuestionDraft.isEmpty { askSideQuestion(chat) }
            return
        }
        if chat.busy || checkpointRestorationBlocks(chat) || !chat.pendingSettings.isEmpty || !chat.deliveryPaused && !chat.pendingPrompts.isEmpty {
            enqueuePrompt(chat, text: text, policy: policy ?? chat.deliveryPolicy)
            return
        }
        startPrompt(chat, text: text, attachments: chat.attachments)
    }
    func canDeliver(_ chat: ChatSession) -> Bool {
        !showNewBranch && !changingBranch && !shuttingDown && !sessionToolMutations.contains(chat.id) && !chat.closing && !chat.launching && !chat.configuring && !chat.forking && loaded[chat.id] === chat
    }
    func startPrompt(_ chat: ChatSession, text: String, attachments: [Attachment], queuedID: UUID? = nil) {
        guard !checkpointRestorationBlocks(chat) else { return }
        if let index = sessions.firstIndex(where: { $0.id == chat.id }), sessions[index].attention?.kind == .completed {
            sessions[index].attention = nil; attentionNotifications?.clear(sessionID: chat.id); persistIndex()
        }
        chat.awaitingWorkCompletion = false
        chat.preparingPrompt = true
        let operation = UUID(); chat.promptOperation = operation
        chat.promptTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if chat.promptOperation == operation {
                    chat.preparingPrompt = false; chat.promptTask = nil; chat.promptOperation = nil; chat.promptDeliveryID = nil
                    driveDelivery(chat)
                }
            }
            let creatingSession = chat.transcript.remoteID == nil || (chat.transcript.remoteUnprompted == true && chat.transcript.items.isEmpty)
            let initialConfiguration = chat.transcript.pendingConfiguration
            var preparedGeneration: UUID?
            var registeredID: UUID?
            var submitted = false
            do {
                try Task.checkCancellation()
                try await self.connect(chat)
                preparedGeneration = chat.setupGeneration
                try Task.checkCancellation()
                guard let peer = chat.connection, let remoteID = chat.transcript.remoteID else { throw ACPError.workspace("Agent disconnected before the prompt was submitted.") }
                if let queuedID { try validatePromptOwner(chat, id: queuedID) }
                if let queuedID, chat.pendingPrompts.first(where: { $0.id == queuedID })?.text != text { return }
                if let queuedID { try await validatePullRequestFixPrompt(chat, id: queuedID, text: text) }
                if let queuedID { try await validateCodeReviewPrompt(chat, id: queuedID, text: text) }
                if let queuedID { try await validateReviewFeedbackPrompt(chat, id: queuedID, text: text) }
                let blocks = try await promptBlocks(chat, text: text, attachments: attachments)
                try Task.checkCancellation()
                guard chat.promptOperation == operation, canDeliver(chat), queuedID == nil || !chat.deliveryPaused else { throw CancellationError() }
                if let queuedID, chat.pendingPrompts.first(where: { $0.id == queuedID })?.text != text { return }
                let id = try registerSubmission(chat, text: text, attachments: attachments, id: queuedID, policy: .nextTurn, startedSession: creatingSession)
                chat.promptDeliveryID = id; registeredID = id
                chat.sentPrompt = text
                if queuedID == nil { consumeDraft(chat, text: text, attachments: attachments) }
                chat.state = .running
                if chat.transcript.codeReview?.id == id {
                    chat.transcript.codeReview?.status = .running
                    chat.transcript.codeReview?.findings = []
                    chat.transcript.codeReview?.details = nil
                }
                if let i = sessions.firstIndex(where: { $0.id == chat.id }) {
                    sessions[i].updatedAt = Date()
                    if sessions[i].importedFromAgent == true { chat.transcript.historyUpdatedAt = sessions[i].updatedAt }
                    if sessions[i].title == "New session" { sessions[i].title = String(text.prefix(64)) }
                }
                try await persistDelivery(chat)
                try Task.checkCancellation()
                guard chat.promptOperation == operation, chat.state != .stopping, queuedID == nil || !chat.deliveryPaused else { throw CancellationError() }
                chat.transcript.remoteUnprompted = nil
                submitted = true
                var promptParameters: JSONValue = ["sessionId": .string(remoteID), "prompt": .array(blocks)]
                if FileCheckpointReference.validCapability(fileCheckpointCapability(chat)) {
                    promptParameters["_meta"] = ["ccode": ["promptId": .string(id.uuidString)]]
                }
                let result = try await peer.request("session/prompt", params: promptParameters, timeout: .seconds(24 * 60 * 60))
                guard chat.promptOperation == operation else { return }
                let reason = result["stopReason"].string
                await completeCodeReview(chat, id: id, reason: reason)
                guard chat.promptOperation == operation else { return }
                settleDelivery(chat, id: id, state: reason == "cancelled" ? .cancelled : .acknowledged)
                if let row = chat.transcript.items.firstIndex(where: { $0.id == id }) { chat.transcript.items[row].deliveryStopReason = reason }
                if reason == "cancelled" { chat.transcript.interruptTools(.stopped) }
                chat.transcript.beginTurn()
                if reason != "end_turn" { chat.transcript.appendNotice(reason == "cancelled" ? "Response stopped" : "Turn ended: \(reason)") }
                chat.state = .ready; chat.sentPrompt = ""
                finishAttention(chat, reason: reason)
                await save(chat); await refreshWorkspace(chat)
            } catch {
                guard chat.promptOperation == operation else { return }
                failCodeReview(chat, id: registeredID ?? queuedID, error: error)
                if submitted { interruptDelivery(chat); chat.transcript.interruptTools(.interrupted) }
                else if let registeredID {
                    returnToQueue(chat, id: registeredID)
                    if queuedID == nil, chat.draft.isEmpty, chat.attachments.isEmpty {
                        try? restorePendingPrompt(chat, id: registeredID)
                    } else if !(error is CancellationError) || queuedID == nil { failQueuedPrompt(chat, id: registeredID, error: error) }
                } else if let queuedID, !(error is CancellationError) { failQueuedPrompt(chat, id: queuedID, error: error) }
                if creatingSession, !submitted, preparedGeneration == chat.setupGeneration {
                    // A new agent session may not be durable until its first prompt.
                    resetUnpromptedSession(chat, configuration: initialConfiguration)
                    await disconnect(chat, preservingPrompt: operation)
                }
                guard chat.promptOperation == operation else { return }
                if error is CancellationError { chat.state = chat.connection == nil ? .idle : .ready }
                else { chat.state = .failed; recordFailure(chat, error: error, deliveryID: submitted ? registeredID : nil) }
                await save(chat)
            }
        }
    }

    func stop(_ chat: ChatSession) {
        dictation.cancel(for: .chat(chat.id)); dictation.cancel(for: .sideQuestion(chat.id))
        cancelSessionToolRequests(chat.id)
        cancelNativeAccess(chat)
        chat.liveConfigurationTask?.cancel()
        if chat.previewStarting { chat.previewTask?.cancel(); Task { await stopPreview(chat) } }
        if let discard = chat.discardTask { discard.cancel(); return }
        if let action = chat.workspaceActionTask { action.cancel(); return }
        guard !chat.restoringFiles else { return }
        chat.reviewOperation = nil
        interruptCodeReview(chat, details: "Review stopped. Request a fresh review when ready.")
        pauseSettings(chat)
        pauseDelivery(chat)
        if chat.attachingFiles { cancelAttachmentImports(chat) }
        if chat.forking { chat.connectionGeneration = UUID(); Task { await disconnect(chat) }; return }
        if chat.launching { chat.launching = false; return }
        if chat.preparingPrompt, chat.state != .running {
            chat.promptTask?.cancel()
            if chat.state == .connecting { Task { await disconnect(chat) } }
            return
        }
        if chat.state == .connecting { chat.promptTask?.cancel(); Task { await disconnect(chat) }; return }
        guard chat.state == .running else { return }
        chat.awaitingWorkCompletion = false
        chat.state = .stopping; cancelApprovals(chat)
        Task { do { try await chat.connection?.notify("session/cancel", params: ["sessionId": .string(chat.transcript.remoteID ?? "")]) } catch { chat.lastError = error.localizedDescription } }
    }
    func applyConfiguration(_ chat: ChatSession, id: String, value: JSONValue) async throws {
        guard !checkpointRestorationBlocks(chat) else { throw ACPError.workspace("Wait for file restoration to finish.") }
        guard let peer = chat.connection, let session = chat.transcript.remoteID else { throw ACPError.workspace("Session is not connected.") }
        guard let option = chat.transcript.configOptions.first(where: { $0["id"].string == id }) else { throw ACPError.workspace("This agent no longer offers the selected configuration: \(id).") }
        var params: JSONValue = ["sessionId": .string(session), "configId": .string(id), "value": value]
        if option["type"].string == "boolean" {
            guard case .bool = value else { throw ACPError.workspace("Choose an on/off value for \(option["name"].string).") }
            params["type"] = "boolean"
        } else {
            let choices = option["options"].array.flatMap { $0["options"].isNull ? [$0] : $0["options"].array }
            guard option["type"].string == "select", value.optionalString != nil, option["currentValue"] == value || choices.contains(where: { $0["value"] == value }) else { throw ACPError.workspace("This agent no longer offers the selected \(option["name"].string) value.") }
        }
        if option["currentValue"] == value { return }
        let generation = chat.connectionGeneration
        let result = try await peer.request("session/set_config_option", params: params)
        try Task.checkCancellation()
        guard chat.connectionGeneration == generation, chat.connection === peer, chat.transcript.remoteID == session else { throw CancellationError() }
        chat.transcript.configure(result)
        guard chat.transcript.configOptions.first(where: { $0["id"].string == id })?["currentValue"] == value else { throw ACPError.workspace("Agent did not accept the selected \(option["name"].string) value.") }
    }
    func setConfig(_ chat: ChatSession, id: String, value: JSONValue) async {
        await requestSetting(chat, key: id, value: value, legacy: false)
    }
    func applyLegacy(_ chat: ChatSession, key: String, id: String) async throws {
        guard let peer = chat.connection, let session = chat.transcript.remoteID else { throw ACPError.workspace("Session is not connected.") }
        guard chat.transcript.configOptions.isEmpty, ["modeId", "modelId"].contains(key) else { throw ACPError.workspace("This agent now uses configuration options. Continue with current agent settings to proceed.") }
        let model = key == "modelId", state = model ? chat.transcript.models : chat.transcript.modes
        guard state[model ? "availableModels" : "availableModes"].array.contains(where: { $0[model ? "modelId" : "id"].string == id }) else { throw ACPError.workspace("This agent no longer offers the selected \(model ? "model" : "mode").") }
        if state[model ? "currentModelId" : "currentModeId"].string == id { return }
        let generation = chat.connectionGeneration
        _ = try await peer.request(model ? "session/set_model" : "session/set_mode", params: ["sessionId": .string(session), key: .string(id)])
        try Task.checkCancellation()
        guard chat.connectionGeneration == generation, chat.connection === peer, chat.transcript.remoteID == session else { throw CancellationError() }
        if model { chat.transcript.models["currentModelId"] = .string(id) }
        else { chat.transcript.modes["currentModeId"] = .string(id) }
    }
    func setLegacy(_ chat: ChatSession, key: String, id: String) async {
        await requestSetting(chat, key: key, value: .string(id), legacy: true)
    }

    private func receive(_ batch: [JSONValue], chat: ChatSession, generation: UUID) {
        guard chat.connectionGeneration == generation else { return }
        if chat.transcript.remoteID == nil { chat.pendingSessionEvents += batch; return }
        for event in batch {
            if chat.loadingHistory {
                if chat.historyReplay?.applyAsyncWork(event, children: chat.childOwners, owners: &chat.asyncTaskOwners) == true { continue }
            } else if chat.transcript.applyAsyncWork(event, children: chat.childOwners, owners: &chat.asyncTaskOwners) { continue }
            if chat.loadingHistory {
                if chat.historyReplay?.applyAgentWork(event, owners: &chat.childOwners) == true { continue }
            } else if chat.transcript.applyAgentWork(event, owners: &chat.childOwners) { continue }
            if event["sessionId"].string != chat.transcript.remoteID { continue }
            if !chat.loadingHistory, event["update"]["sessionUpdate"].string == "user_message_chunk", !supportsMessageFork(chat) { continue }
            if chat.loadingHistory { _ = chat.historyReplay?.apply(event) }
            else { _ = chat.transcript.apply(event) }
            if event["update"]["sessionUpdate"].string == "session_info_update", let title = event["update"]["title"].optionalString,
               let i = sessions.firstIndex(where: { $0.id == chat.id }) {
                var info = sessions[i]
                if info.importedFromAgent != true || info.title == info.agentTitle { info.title = title }
                info.agentTitle = title
                if info != sessions[i] { sessions[i] = info; persistIndex() }
            }
        }
        if !chat.loadingHistory {
            if chat.awaitingWorkCompletion, !chat.hasLiveAgentWork, chat.state == .ready {
                settleWorkAttention(chat)
            }
            refreshChatActivity(chat.id)
        }
        if !chat.loadingHistory, chat.saveTask == nil {
            chat.saveTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                await self?.save(chat); chat.saveTask = nil
            }
        }
    }
    private func callback(_ method: String, params: JSONValue, chat: ChatSession, generation: UUID) async throws -> JSONValue {
        guard chat.connectionGeneration == generation else { throw CancellationError() }
        if method == "elicitation/create" {
            let request = try ElicitationRequest(params: params)
            if let session = request.sessionID {
                guard chat.ownsAgentSession(session) else { throw ACPError.remote(-32602, "Interaction belongs to a different session.") }
            } else if let id = request.requestID {
                guard await chat.connection?.hasPendingRequest(id) == true, chat.connectionGeneration == generation else { throw ACPError.remote(-32602, "Interaction has no active request on this connection.") }
            }
            if let id = request.elicitationID {
                guard !chat.interactions.contains(where: { $0.request.elicitationID == id }), !chat.urlInteractions.contains(where: { $0.id == id }) else { throw ACPError.remote(-32602, "Duplicate external interaction identity.") }
            }
            guard chat.interactions.count < 16 else { throw ACPError.remote(-32602, "Too many pending interactions.") }
            let id = UUID()
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    chat.interactions.append(PendingInteraction(id: id, request: request, continuation: continuation))
                }
            } onCancel: { Task { @MainActor in try? self.resolveInteraction(chat, id: id, action: .cancel) } }
        }
        guard let remoteID = chat.transcript.remoteID, let owner = params["sessionId"].optionalString,
              chat.ownsAgentSession(owner) else { throw ACPError.workspace("Agent callback belongs to a different session.") }
        switch method {
        case "session/request_permission":
            let approvalID = UUID()
            let tool = params["toolCall"]
            let streamed = chat.transcript.agentItems(owner: owner).last { $0.kind == "tool" && $0.tool["toolCallId"] == tool["toolCallId"] }?.tool ?? [:]
            var preview = streamed.merging(tool)
            if tool["rawInput"].isNull { preview["rawInput"] = streamed["rawInput"] }
            else if case .object = streamed["rawInput"], case .object = tool["rawInput"] {
                preview["rawInput"] = streamed["rawInput"].merging(tool["rawInput"])
            }
            if tool["content"].array.isEmpty { preview["content"] = streamed["content"] }
            if owner == remoteID, supportsMessageFork(chat), PermissionPresentation(tool: preview).canRevise,
               PermissionPresentation(tool: preview).plan == nil,
               let snapshot = PermissionPresentation.planSnapshot(items: chat.transcript.items) {
                preview["rawInput"]["plan"] = .string(snapshot.text)
                preview["_meta"]["ccode"]["planSourcePath"] = .string(snapshot.path)
            }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    chat.approvals.append(Approval(id: approvalID, request: params, continuation: continuation, previewTool: preview))
                }
            } onCancel: { Task { @MainActor in self.resolveApproval(chat, id: approvalID, option: nil) } }
        case "fs/read_text_file":
            let text = try await chat.workspace.read(params["path"].string, line: params["line"].isNull ? nil : params["line"].int, limit: params["limit"].isNull ? nil : params["limit"].int)
            return ["content": .string(text)]
        case "fs/write_text_file":
            guard let content = params["content"].optionalString else { throw ACPError.workspace("Missing file content.") }
            try await chat.workspace.write(params["path"].string, content: content); return [:]
        case "terminal/create":
            let cwd = params["cwd"].optionalString ?? chat.workspace.root
            let directory = try await chat.workspace.scoped(cwd)
            let args = params["args"].array.map(\.string)
            var env: [String: String] = [:]
            for value in params["env"].array { env[value["name"].string] = value["value"].string }
            let id = try await chat.workspace.createTerminal(chat.terminals, command: params["command"].string, arguments: args, directory: directory.path, environment: env, localEnvironment: AgentSettings.environment, byteLimit: params["outputByteLimit"].isNull ? 1024 * 1024 : params["outputByteLimit"].int)
            return ["terminalId": .string(id)]
        case "terminal/output": return try await chat.terminals.output(params["terminalId"].string)
        case "terminal/wait_for_exit": return ["exitStatus": try await chat.terminals.wait(params["terminalId"].string)]
        case "terminal/kill": try await chat.terminals.kill(params["terminalId"].string); return [:]
        case "terminal/release": try await chat.terminals.release(params["terminalId"].string); return [:]
        default: throw ACPError.methodNotFound(method)
        }
    }
    func resolveApproval(_ chat: ChatSession, id: UUID, option: String?) {
        guard let index = chat.approvals.firstIndex(where: { $0.id == id }) else { return }
        if option != nil, chat.approvals[index].submittingRevision { return }
        if let option, !chat.approvals[index].request["options"].array.contains(where: { $0["optionId"].string == option }) {
            chat.approvals[index].error = "This permission choice is no longer available. Select one of the offered options."
            return
        }
        let approval = chat.approvals.remove(at: index)
        if let option, approval.request["options"].array.contains(where: { $0["optionId"].string == option }) {
            approval.continuation.resume(returning: ["outcome": ["outcome": "selected", "optionId": .string(option)]])
        } else { approval.continuation.resume(returning: ["outcome": ["outcome": "cancelled"]]) }
    }
    func resolveInteraction(_ chat: ChatSession, id: UUID, action: ElicitationAction, content: JSONValue = [:]) throws {
        guard let index = chat.interactions.firstIndex(where: { $0.id == id }) else { return }
        let interaction = chat.interactions[index]
        let response = try interaction.request.response(action: action, content: content)
        chat.interactions.remove(at: index)
        if interaction.request.mode == .form {
            let values = interaction.request.fields.map { field -> JSONValue in
                ["title": .string(field.title), "answer": content[field.id]]
            }
            chat.transcript.appendAgentItem(TranscriptItem(kind: "interaction", text: interaction.request.message, tool: ["action": .string(action.rawValue), "content": action == .accept ? content : [:], "answers": action == .accept ? .array(values) : []]), owner: interaction.request.sessionID)
        } else if action == .accept, let identity = interaction.request.elicitationID, let url = interaction.request.url {
            chat.urlInteractions.append(URLInteraction(id: identity, host: url.host ?? "", message: interaction.request.message, sessionID: interaction.request.sessionID))
        }
        interaction.continuation.resume(returning: response)
        Task { await save(chat) }
    }
    private func notification(_ method: String, params: JSONValue, chat: ChatSession, generation: UUID) {
        if chat.connectionGeneration == generation, method == "_ccode/checkpoint" {
            receiveFileCheckpoint(params, chat: chat); return
        }
        guard chat.connectionGeneration == generation, method == "elicitation/complete",
              let index = chat.urlInteractions.firstIndex(where: { $0.id == params["elicitationId"].string }) else { return }
        let interaction = chat.urlInteractions.remove(at: index)
        chat.transcript.appendAgentItem(TranscriptItem(kind: "notice", text: "External interaction completed: \(interaction.host)"), owner: interaction.sessionID)
        Task { await save(chat) }
    }
    private func cancelApprovals(_ chat: ChatSession) {
        for approval in chat.approvals { resolveApproval(chat, id: approval.id, option: nil) }
        for interaction in chat.interactions { try? resolveInteraction(chat, id: interaction.id, action: .cancel) }
        chat.urlInteractions.removeAll()
    }
    private func disconnected(_ chat: ChatSession, reason: String, generation: UUID) {
        guard chat.connectionGeneration == generation else { return }
        chat.pullRequestMonitor?.cancel()
        chat.reviewOperation = nil
        interruptCodeReview(chat, details: "Review disconnected. Request a fresh review when ready.")
        chat.transcript.interruptTools(.disconnected)
        chat.childOwners.removeAll(); chat.transcript.disconnectSubagents(); chat.stoppingSubagents.removeAll()
        chat.asyncTaskOwners.removeAll(); chat.transcript.disconnectAsyncTasks(); chat.stoppingAsyncTasks.removeAll()
        let deliveryID = chat.promptDeliveryID
        pauseSettings(chat)
        interruptDelivery(chat)
        cancelSessionToolRequests(chat.id)
        Task { await stopNativeServer(chat,generation:generation); await stopAppSessionServer(chat,generation:generation) }
        cancelApprovals(chat); chat.connection = nil; chat.state = .failed; recordFailure(chat, error: ACPError.disconnected(reason), deliveryID: deliveryID)
        Task { await save(chat) }
        Task { await chat.terminals.close() }
        Task { if chat.connectionGeneration == generation { await chat.browserWorkspace.disconnectTools() } }
    }
    func disconnect(_ chat: ChatSession, preservingPrompt operation: UUID? = nil, preservingSettings review: UUID? = nil) async {
        await stopNativeServer(chat)
        await stopAppSessionServer(chat)
        closeSideQuestion(chat)
        chat.liveConfigurationTask?.cancel()
        await stopPullRequestMonitoring(chat)
        chat.reviewOperation = nil
        interruptCodeReview(chat, details: "Review disconnected. Request a fresh review when ready.")
        chat.transcript.interruptTools(.disconnected)
        if let restore = chat.fileRestoreTask { pauseDelivery(chat); _ = await restore.value }
        if let discard = chat.discardTask { pauseDelivery(chat); _ = try? await discard.value }
        if let action = chat.workspaceActionTask { pauseDelivery(chat); _ = try? await action.value }
        let generation = UUID(); chat.connectionGeneration = generation
        chat.awaitingWorkCompletion = false
        chat.childOwners.removeAll(); chat.transcript.disconnectSubagents(); chat.stoppingSubagents.removeAll()
        chat.asyncTaskOwners.removeAll(); chat.transcript.disconnectAsyncTasks(); chat.stoppingAsyncTasks.removeAll()
        pauseSettings(chat, preservingReview: review)
        interruptDelivery(chat)
        let preservePrompt = operation != nil && chat.promptOperation == operation
        if !preservePrompt { chat.promptOperation = nil; chat.preparingPrompt = false; chat.promptDeliveryID = nil }
        chat.historyReplay = nil; chat.loadingHistory = false
        cancelApprovals(chat)
        if !preservePrompt { chat.promptTask?.cancel(); chat.promptTask = nil }
        await chat.connection?.close()
        _ = try? await chat.liveConfigurationTask?.value
        guard chat.connectionGeneration == generation else { return }
        chat.connection = nil
        await chat.browserWorkspace.disconnectTools()
        await chat.terminals.close(); chat.state = .idle
    }
    private func closeTerminals(_ chat: ChatSession) async {
        closeSideQuestion(chat)
        chat.closing = true
        await detachSimulator(chat)
        await stopChangeStatistics(chat)
        await stopPreview(chat)
        await chat.browserWorkspace.close()
        for tab in chat.terminalTabs { await tab.close() }
        chat.terminalTabs.removeAll(); chat.activeTerminalID = nil
    }
    func shutdown() async {
        shuttingDown = true
        await stopLocalScheduling()
        dictation.cancel()
        cancelHomeBranch(); _ = await homeBranchTask?.value
        let reads = Array(nativeReadTasks.values)
        for read in reads { read.cancel() }
        for read in reads { _ = await read.value }
        nativeReadTasks.removeAll(); paneLoadGenerations.removeAll(); loadingSessions.removeAll()
        await sessionHistoryPeer?.close(); await cancelHomeDiscovery(); await homeLaunchTask?.value
        cancelHomeAttachmentImports(); await homeAttachmentTask?.value
        await saveNewSessionDraft()
        for chat in loaded.values { await stopPullRequestMonitoring(chat); _ = try? await chat.workspaceActionTask?.value; _ = await chat.fileRestoreTask?.value; _ = try? await chat.discardTask?.value; await closeTerminals(chat); cancelAttachmentImports(chat); await chat.attachmentTask?.value; await disconnect(chat); await chat.settingsTask?.value; await save(chat) }
        await sidebarSaveTask?.value
        await paneLayoutSaveTask?.value
        do { try await storage.savePaneLayout(paneLayout) }
        catch { self.error = "Could not save chat layout: \(error.localizedDescription)" }
    }
    private func evictIdle(except id: UUID?, revision: Int) async {
        for (key, chat) in loaded where key != id && !isChatVisible(key) && !chat.busy && !chat.hasLiveAgentWork && chat.sideQuestionTask == nil && chat.terminalTabs.isEmpty && !chat.previewActive && !chat.browserWorkspace.hasTabs {
            guard selectedID == id, selectionRevision == revision else { return }
            chat.saveTask?.cancel(); chat.saveTask = nil
            await save(chat)
            guard selectedID == id, selectionRevision == revision else { return }
            guard !isChatVisible(key), !chat.busy, !chat.hasLiveAgentWork, chat.sideQuestionTask == nil, chat.terminalTabs.isEmpty, !chat.previewActive, !chat.browserWorkspace.hasTabs else { continue }
            loaded.removeValue(forKey: key); runtimeActivities.removeValue(forKey: key); rebuildSidebar()
            await stopChangeStatistics(chat)
            await disconnect(chat)
        }
    }
    func save(_ chat: ChatSession) async {
        if let index = sessions.firstIndex(where: { $0.id == chat.id }), sessions[index].lastError != chat.lastError { sessions[index].lastError = chat.lastError }
        chat.transcript.draftText = chat.draft.isEmpty ? nil : chat.draft
        chat.transcript.draftAttachments = chat.attachments.isEmpty ? nil : chat.attachments
        chat.transcript.editorDrafts = chat.fileDrafts.filter { $0.value.text != $0.value.original }
        do { try await storage.save(chat.transcript, id: chat.id); try await storage.saveIndex(sessions) }
        catch { self.error = "Could not save session: \(error.localizedDescription)" }
    }
    func checkpointRestoreChats(_ chat: ChatSession) -> [ChatSession] {
        loaded.values.filter { other in
            chat.workspace.environment == other.workspace.environment && chat.workspace.roots.contains { left in other.workspace.roots.contains { right in
                left == right || left.hasPrefix(right == "/" ? "/" : right + "/") || right.hasPrefix(left == "/" ? "/" : left + "/")
            } }
        }
    }
    func checkpointRestorationBlocks(_ chat: ChatSession) -> Bool {
        checkpointRestoreChats(chat).contains { $0.restoringFiles || $0.workspaceWrites > 0 }
    }
    private func persistIndex() { let index = sessions; Task { do { try await storage.saveIndex(index) } catch { self.error = error.localizedDescription } } }

    func attachFiles(_ chat: ChatSession) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        attach(panel.urls, to: chat)
    }
    func attach(_ url: URL, to chat: ChatSession) {
        attach([url], to: chat)
    }
    func attachContext(_ candidate: ContextCandidate, to chat: ChatSession, replacing query: PromptQuery? = nil) async -> Bool {
        await importPromptContext(chat, replacing: query) { try await self.storage.importWorkspaceContext(candidate, workspace: chat.workspace) }
    }
    func attachSelectedContext(_ snapshot: SelectedContext, to chat: ChatSession) async -> Bool {
        await importPromptContext(chat) {
            guard chat.workspace.roots.contains(snapshot.context.root),
                  try await chat.workspace.scoped(snapshot.context.path).path == (snapshot.context.resolvedPath ?? snapshot.context.path) else { throw ACPError.workspace("Selection belongs to a different workspace or its path changed.") }
            return try await self.storage.importSelectedContext(snapshot)
        }
    }
    private func importPromptContext(_ chat: ChatSession, replacing query: PromptQuery? = nil, importer: @escaping @MainActor () async throws -> Attachment) async -> Bool {
        guard !chat.closing, !shuttingDown, !chat.preparingPrompt || chat.state == .running, loaded[chat.id] === chat,
              !chat.attachingFiles, chat.attachmentTask == nil else { return false }
        guard chat.attachments.count < PromptAttachment.countLimit else { error = "The attachment limit is 10 files."; return false }
        let originalDraft = chat.draft
        var accepted = false
        chat.attachingFiles = true
        chat.attachmentReservation = 1
        let operation = Task {
            defer {
                chat.attachingFiles = false; chat.attachmentTask = nil; chat.attachmentReservation = 0
                if Task.isCancelled { chat.pendingAttachmentInputs = [] }
                else if !chat.pendingAttachmentInputs.isEmpty { attachInputs([], to: chat) }
            }
            do {
                let attachment = try await importer()
                do {
                    if let context = attachment.context {
                        guard try await chat.workspace.scoped(context.path).path == (context.resolvedPath ?? context.path) else { throw ACPError.workspace("The context path changed while loading. Select it again.") }
                    }
                    try Task.checkCancellation()
                    guard !chat.closing, !shuttingDown, loaded[chat.id] === chat else { throw CancellationError() }
                    guard chat.attachments.reduce(attachment.promptBytes, { $0 + $1.promptBytes }) < PromptAttachment.promptLimit else { throw ACPError.workspace("Prompt attachment limit is 6 MB / 10 files.") }
                } catch { try? await storage.discardAttachment(attachment); throw error }
                chat.attachments.append(attachment)
                chat.attachmentReservation = 0
                if let query, chat.draft == originalDraft { chat.draft = query.removing(from: originalDraft) }
                accepted = true
                await save(chat)
            } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
        }
        chat.attachmentTask = operation
        await withTaskCancellationHandler { await operation.value } onCancel: { operation.cancel() }
        return accepted
    }
    func attach(_ urls: [URL], to chat: ChatSession) {
        attachInputs(urls.map(AttachmentInput.file), to: chat)
    }
    @discardableResult func attachProviders(_ providers: [NSItemProvider], to chat: ChatSession) -> Bool {
        let supported = providers.filter(AttachmentInput.supported)
        guard !supported.isEmpty else { return false }
        attachInputs(supported.map(AttachmentInput.provider), to: chat)
        return true
    }
    func attachInputs(_ inputs: [AttachmentInput], to chat: ChatSession) {
        guard !chat.closing, !shuttingDown, loaded[chat.id] === chat else { return }
        guard chat.attachmentTask?.isCancelled != true, chat.attachments.count + chat.pendingAttachmentInputs.count + inputs.count + chat.attachmentReservation <= PromptAttachment.countLimit else { error = "Wait for file loading to finish; the attachment limit is 10 files."; return }
        guard chat.attachmentResidentBytes + (chat.pendingAttachmentInputs + inputs).reduce(0, { $0 + $1.residentBytes }) < SessionStorage.imageInputLimit else { error = "Queued image data limit is 32 MB."; return }
        chat.pendingAttachmentInputs += inputs
        guard !chat.pendingAttachmentInputs.isEmpty, chat.attachmentTask == nil else { return }
        chat.attachingFiles = true
        chat.attachmentTask = Task {
            defer { chat.attachingFiles = false; chat.pendingAttachmentInputs = []; chat.attachmentTask = nil; chat.attachmentReservation = 0; chat.attachmentResidentBytes = 0 }
            while !chat.pendingAttachmentInputs.isEmpty, !Task.isCancelled, !chat.closing, !shuttingDown {
                let input = chat.pendingAttachmentInputs.removeFirst()
                chat.attachmentReservation = 1; chat.attachmentResidentBytes = input.residentBytes
                do {
                    let attachment = try await input.snapshot(using: storage)
                    do {
                        try Task.checkCancellation()
                        guard !chat.closing, !shuttingDown, loaded[chat.id] === chat else { throw CancellationError() }
                        guard chat.attachments.reduce(attachment.promptBytes, { $0 + $1.promptBytes }) < PromptAttachment.promptLimit else { throw ACPError.workspace("Prompt attachment limit is 6 MB / 10 files.") }
                    } catch { try? await storage.discardAttachment(attachment); throw error }
                    chat.attachments.append(attachment)
                    chat.attachmentReservation = 0
                    await save(chat)
                } catch {
                    if !(error is CancellationError) { self.error = error.localizedDescription }
                }
                chat.attachmentReservation = 0; chat.attachmentResidentBytes = 0
            }
        }
    }
    func cancelAttachmentImports(_ chat: ChatSession) { chat.attachmentTask?.cancel(); chat.pendingAttachmentInputs = [] }
    func removeAttachment(_ attachment: Attachment, from chat: ChatSession) async {
        guard !chat.closing, !chat.preparingPrompt else { return }
        chat.attachments.removeAll { $0.id == attachment.id }
        // ponytail: retain snapshots for saved history/fork links; prune unreferenced assets when disk growth warrants it.
        await save(chat)
    }
    func attachmentURL(_ attachment: Attachment) -> URL { storage.attachmentURL(attachment) }
    func export(_ chat: ChatSession) {
        let title = sessions.first { $0.id == chat.id }?.title ?? "session"
        let panel = NSSavePanel(); panel.nameFieldStringValue = "\(title).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let captured = chat.transcript
        Task { do { _ = try await storage.exportTranscript(captured, title: title, to: url) } catch { self.error = error.localizedDescription } }
    }
}


extension AppStore {
    func recordFailure(_ chat: ChatSession, error: any Error, deliveryID: UUID? = nil) {
        let failure = AgentFailure(error: error, deliveryID: deliveryID, providerMetadata: supportsMessageFork(chat))
        chat.lastError = failure.details
        chat.failure = failure
    }
    func recoverConnection(_ chat: ChatSession, authentication: String? = nil) async {
        guard canDeliver(chat), !chat.busy else { return }
        do { try await connect(chat, authentication: authentication) }
        catch {
            guard !(error is CancellationError), loaded[chat.id] === chat, !chat.closing, !shuttingDown else { return }
            recordFailure(chat, error: error)
            await save(chat)
        }
        // Only connection/authentication is recovered. Never call driveDelivery,
        // Send or Resume here: a failed turn may already have changed files.
    }
}


extension AppStore {
    func sessionActivity(_ id: UUID) -> SessionActivity {
        guard let info = sessions.first(where: { $0.id == id }) else { return .idle }
        if let chat = loaded[id] {
            if chat.hasPendingDecisions || chat.lastError != nil || info.attention?.kind == .failed { return .needsAttention }
            if chat.busy || chat.hasLiveAgentWork { return .working }
            if info.attention?.kind == .completed { return .completed }
            return .idle
        }
        return info.persistedActivity
    }
    func isSessionBeingViewed(_ id: UUID) -> Bool {
        if let sessionIsBeingViewed { return sessionIsBeingViewed(id) }
        guard NSApp?.isActive == true else { return false }
        return chatWindows?.isSessionPresented(id) == true
    }
    func observeAttention(_ chat: ChatSession) {
        chat.activityDidChange = { [weak self, weak chat] in
            guard let self, let chat, self.loaded[chat.id] === chat, !self.shuttingDown, !chat.closing else { return }
            if chat.hasPendingDecisions { self.publishAttention(chat, kind: .needsInput) }
            else if chat.lastError != nil { self.publishAttention(chat, kind: .failed) }
            else if let index = self.sessions.firstIndex(where: { $0.id == chat.id }),
                    [.needsInput, .failed].contains(self.sessions[index].attention?.kind) {
                self.sessions[index].attention = nil
                self.attentionNotifications?.clear(sessionID: chat.id); self.persistIndex()
            }
            self.refreshChatActivity(chat.id)
        }
        refreshChatActivity(chat.id)
    }
    private func refreshChatActivity(_ id: UUID) {
        let value = sessionActivity(id)
        guard runtimeActivities[id] != value else { return }
        runtimeActivities[id] = value; rebuildSidebar()
    }
    private func publishAttention(_ chat: ChatSession, kind: SessionAttentionReceipt.Kind) {
        guard !shuttingDown, !chat.closing, loaded[chat.id] === chat,
              let index = sessions.firstIndex(where: { $0.id == chat.id && !$0.archived }),
              sessions[index].attention?.kind != kind else { return }
        if kind == .completed, isSessionBeingViewed(chat.id) { return }
        let receipt = SessionAttentionReceipt(kind: kind)
        sessions[index].attention = receipt
        persistIndex()
        if !isSessionBeingViewed(chat.id) { attentionNotifications?.deliver(SessionNotice(sessionID: chat.id, receipt: receipt)) }
    }
    func finishAttention(_ chat: ChatSession, reason: String) {
        chat.awaitingWorkCompletion = reason == "end_turn" && chat.lastError == nil
        if chat.awaitingWorkCompletion, !chat.hasLiveAgentWork { settleWorkAttention(chat) }
        refreshChatActivity(chat.id)
    }
    private func settleWorkAttention(_ chat: ChatSession) {
        chat.awaitingWorkCompletion = false
        let failed = (chat.transcript.subagents ?? []).contains { chat.childOwners.contains($0.id) && $0.state == "failed" }
            || (chat.transcript.asyncTasks ?? []).contains { chat.asyncTaskOwners.contains($0.id) && $0.state == .failed }
        publishAttention(chat, kind: failed ? .failed : .completed)
    }
    func acknowledgeVisibleCompletions() {
        guard !loading, !shuttingDown else { return }
        var changed = false
        for index in sessions.indices where sessions[index].attention?.kind == .completed && isSessionBeingViewed(sessions[index].id) {
            let id = sessions[index].id
            sessions[index].attention = nil; attentionNotifications?.clear(sessionID: id)
            runtimeActivities[id] = sessionActivity(id); changed = true
        }
        if changed { rebuildSidebar(); persistIndex() }
    }
    func openSessionNotification(sessionID: UUID, receiptID: UUID) async -> Bool {
        guard !shuttingDown, sessions.contains(where: { $0.id == sessionID && !$0.archived && $0.attention?.id == receiptID }) else { return false }
        await select(sessionID)
        guard selectedID == sessionID else { return false }
        chatWindows?.showFocusedWindow()
        acknowledgeVisibleCompletions()
        return true
    }
}


extension AppStore {
    func supportsSideQuestions(_ chat: ChatSession) -> Bool {
        let cap=chat.handshake["_meta"]["ccode"]["sideQuestions"]
        return cap["version"] == 1 && cap["method"] == "_ccode/side_question" && cap["cancelMethod"] == "_ccode/side_question/cancel" && cap["connectionId"].optionalString.flatMap(UUID.init(uuidString:)) != nil
    }
    func toggleSideQuestion(_ chat: ChatSession) {
        guard loaded[chat.id] === chat, !chat.closing, !shuttingDown else { return }
        if chat.showSideQuestion { closeSideQuestion(chat) } else { chat.showSideQuestion=true }
    }
    func askSideQuestion(_ chat: ChatSession) {
        let question=chat.sideQuestionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard loaded[chat.id] === chat, !shuttingDown, !chat.closing, chat.sideQuestionTask == nil else { return }
        guard SideQuestionReply.validText(question,limit:8192) else { chat.sideQuestionError="Enter a side question of up to 8 KB.";return }
        let operation=UUID();chat.sideQuestionOperation=operation;chat.showSideQuestion=true;chat.sideQuestionError=nil
        chat.sideQuestionTask=Task { [weak self, weak chat] in
            guard let self, let chat else { return }
            defer { if chat.sideQuestionOperation == operation { chat.sideQuestionTask=nil;chat.sideQuestionOperation=nil;chat.sideQuestionRequest=nil } }
            do {
                try Task.checkCancellation()
                if chat.connection == nil { try await connect(chat) }
                try Task.checkCancellation()
                guard loaded[chat.id] === chat, chat.sideQuestionOperation == operation, !chat.closing,
                      supportsSideQuestions(chat), let peer=chat.connection, let session=chat.transcript.remoteID,
                      let connection=chat.handshake["_meta"]["ccode"]["sideQuestions"]["connectionId"].optionalString.flatMap(UUID.init(uuidString:)) else {
                    throw ACPError.workspace("This agent connection does not support read-only side questions. The main chat remains available.")
                }
                let generation=chat.connectionGeneration
                let history=chat.sideQuestionHistory.suffix(4).map { item -> JSONValue in ["question":.string(item.question),"response":.string(item.response)] }
                chat.sideQuestionRequest=(peer,session,connection,operation)
                let response=try await peer.request("_ccode/side_question",params:["sessionId":.string(session),"connectionId":.string(connection.uuidString),"questionId":.string(operation.uuidString),"question":.string(question),"history":.array(history)],timeout:.seconds(180))
                try Task.checkCancellation()
                guard loaded[chat.id] === chat, chat.sideQuestionOperation == operation, chat.connectionGeneration == generation, chat.connection === peer, chat.transcript.remoteID == session, !chat.closing else { return }
                let result=try SideQuestionReply(response,sessionID:session,connectionID:connection,questionID:operation)
                guard let answer=result.answer, !result.synthetic else { throw ACPError.workspace("Claude did not provide an answer for this side question. Ask again or use the main chat.") }
                chat.sideQuestionHistory.append(SideQuestionExchange(question:question,response:answer))
                chat.sideQuestionHistory=Array(chat.sideQuestionHistory.suffix(4))
                if chat.sideQuestionDraft.trimmingCharacters(in: .whitespacesAndNewlines) == question { chat.sideQuestionDraft="" }
            } catch {
                guard chat.sideQuestionOperation == operation else { return }
                if let request=chat.sideQuestionRequest { await cancelSideQuestionRequest(request) }
                guard chat.sideQuestionOperation == operation else { return }
                if !(error is CancellationError) { chat.sideQuestionError="Could not answer this side question. Your question is preserved; the main conversation continues." }
            }
        }
    }
    func cancelSideQuestion(_ chat: ChatSession) {
        let request=chat.sideQuestionRequest
        chat.sideQuestionOperation=nil;chat.sideQuestionRequest=nil
        chat.sideQuestionTask?.cancel();chat.sideQuestionTask=nil
        if let request { Task { await cancelSideQuestionRequest(request) } }
    }
    private func cancelSideQuestionRequest(_ request: (peer: ACPConnection, session: String, connection: UUID, question: UUID)) async {
        _ = try? await request.peer.request("_ccode/side_question/cancel",params:["sessionId":.string(request.session),"connectionId":.string(request.connection.uuidString),"questionId":.string(request.question.uuidString)],timeout:.seconds(10))
    }
    func closeSideQuestion(_ chat: ChatSession) {
        dictation.cancel(for: .sideQuestion(chat.id))
        cancelSideQuestion(chat);chat.showSideQuestion=false;chat.editingSideQuestion=false;chat.sideQuestionHistory=[];chat.sideQuestionDraft="";chat.sideQuestionError=nil
    }
}
