import Foundation
import Observation


@MainActor
public protocol AudioCaptureManaging: Sendable {
    func start(
        mode: AudioSourceMode,
        audioHandler: @escaping @Sendable (Data) -> Void,
        errorHandler: (@Sendable (String) -> Void)?
    ) async throws
    func start(
        mode: AudioSourceMode,
        audioHandler: @escaping @Sendable (Data) -> Void,
        errorHandler: (@Sendable (String) -> Void)?,
        recordingSessionID: UUID?,
        recordingHandler: (@Sendable (UUID, AudioRecordingSource, Data, MediaTime) -> Void)?
    ) async throws
    func stop() async
}

extension AudioCaptureManaging {
    func start(
        mode: AudioSourceMode,
        audioHandler: @escaping @Sendable (Data) -> Void,
        errorHandler: (@Sendable (String) -> Void)?,
        recordingSessionID: UUID?,
        recordingHandler: (@Sendable (UUID, AudioRecordingSource, Data, MediaTime) -> Void)?
    ) async throws {
        try await start(mode: mode, audioHandler: audioHandler, errorHandler: errorHandler)
    }
}

protocol RealtimeTranscribing: Sendable {
    func connect(
        apiKey: String,
        model: TranscriptionModel,
        context: String,
        eventHandler: @escaping @Sendable (TranscriptionEvent) -> Void
    ) async throws
    func send(audioPCM16 data: Data) async
    func disconnect() async
}

/// Capture backend used when none is injected (tests). Real capture is platform specific and supplied by the host app.
@MainActor
struct UnavailableAudioCapture: AudioCaptureManaging {
    struct Unavailable: LocalizedError {
        var errorDescription: String? { "Audio capture is not available on this platform." }
    }

    func start(
        mode: AudioSourceMode,
        audioHandler: @escaping @Sendable (Data) -> Void,
        errorHandler: (@Sendable (String) -> Void)?
    ) async throws {
        throw Unavailable()
    }

    func stop() async {}
}

extension RealtimeTranscriptionClient: RealtimeTranscribing {}

private enum AppModelPostCallError: LocalizedError {
    case noRecognizedSpeech

    var errorDescription: String? {
        switch self {
        case .noRecognizedSpeech: "No usable speech was returned. The temporary recording was retained for retry or deletion."
        }
    }
}

@MainActor
@Observable
public final class AppModel {
    public var sourceMode: AudioSourceMode = .microphone {
        didSet { if !isApplyingSavedSession && oldValue != sourceMode { recordSessionMutation(immediate: true) } }
    }
    public var transcriptionModel: TranscriptionModel = .live {
        didSet { if !isApplyingSavedSession && oldValue != transcriptionModel { recordSessionMutation(immediate: true) } }
    }
    public private(set) var phase: ListeningPhase = .idle
    public private(set) var transcriptEntries: [TranscriptEntry] = []
    public private(set) var postCallTranscriptEntries: [TranscriptEntry] = []
    public private(set) var postCallRevisionID: UUID?
    public private(set) var postCallStatus: String?
    public private(set) var postCallMessage: String?
    public private(set) var postCallAudioExpiresAt: Date?
    public private(set) var postCallRecordingIDs: [UUID] = []
    private(set) var postCallLiveEntryIDs: Set<String> = []
    public private(set) var postCallKeepUntilReviewed = false
    private(set) var postCallHasCoverageGaps = false
    public var showsPostCallTranscript = false
    public var batchTranscriptionModel = "" {
        didSet { if !isApplyingSavedSession && oldValue != batchTranscriptionModel { recordSessionMutation(immediate: true) } }
    }
    public private(set) var contextLimits = ContextRunLimits.defaults
    public private(set) var contextGuidance = ContextGuidance.defaultText
    public var temporaryRecordingEnabled = true
    public private(set) var contextFinding: AgentFinding?
    public private(set) var contextUpdatedAt: Date?
    public private(set) var contextMessage: String?
    public private(set) var transcriptionConnectionStatus: String?
    private var activeGapID: String?
    public private(set) var investigations: [PassageInvestigation] = []
    public private(set) var isStopping = false
    public private(set) var isResetting = false
    private(set) var transcript = ""
    private(set) var cues: [Cue] = []
    public private(set) var mediumActivity: TierActivity = .idle
    private(set) var deepActivity: TierActivity = .idle
    private(set) var agentFindings: [AgentFinding] = []
    public private(set) var isDemo = false
    public private(set) var sessionHistory: [SessionSummary] = []
    public private(set) var activeSessionID: UUID?
    public private(set) var sessionTitle = "New conversation"
    public private(set) var persistenceStatus = "Not saved"
    public private(set) var persistenceError: String?
    public private(set) var recordingStatus: String?
    public private(set) var isLoadingHistory = false
    public private(set) var hasSavedTranscriptionCredential = false
    public private(set) var credentialMessage: String?

    public private(set) var workspaceName = "Call only"
    public private(set) var workspaceDocumentCount = 0
    public private(set) var workspaceMessage: String?
    public private(set) var isLoadingWorkspace = false
    public private(set) var workspaceURL: URL?
    public private(set) var recentWorkspaces: [RecentWorkspace] = []
    public private(set) var hasAgentConsent = false
    public private(set) var callAgentsEnabled = false
    private let callConsentDefaults: UserDefaults
    public private(set) var codexModels: [CodexModel] = []
    private(set) var codexSkills: [CodexSkill] = []
    public private(set) var codexMessage = "Enable Context agents and select a model to begin."
    public private(set) var isLoadingCodex = false
    public var contextEffort: ReasoningEffort = .modelDefault {
        didSet { appPreferences.set(contextEffort.rawValue, forKey: ReasoningEffort.contextPreferenceKey) }
    }
    public var investigationEffort: ReasoningEffort = .modelDefault {
        didSet { appPreferences.set(investigationEffort.rawValue, forKey: ReasoningEffort.investigationPreferenceKey) }
    }
    public var contextModel = "" {
        didSet {
            guard !isApplyingSavedSession, oldValue != contextModel else { return }
            modelSelectionStore.rememberContextModel(contextModel)
            recordSessionMutation(immediate: true)
        }
    }
    public var deepModel = "" {
        didSet {
            guard !isApplyingSavedSession, oldValue != deepModel else { return }
            modelSelectionStore.rememberPassageModel(deepModel)
            recordSessionMutation(immediate: true)
        }
    }

    private let workspaceLoader = WorkspaceLoader()
    private let capture: any AudioCaptureManaging
    private let realtime: any RealtimeTranscribing
    private let consentStore: WorkspaceConsentStore
    private let recentWorkspaceStore: RecentWorkspaceStore
    private let agentCoordinator: (any ConversationAgentManaging)?
    private let credentialStore: any TranscriptionCredentialStore
    private let sessionStore: any SessionStoring
    private let recordingStore: AudioRecordingStore?
    private let postCallCoordinator: PostCallTranscriptionCoordinator?
    private let modelSelectionStore: ModelSelectionStore
    private let requiresOpenAIKeyForAgents: Bool
    private let launchAPIKey: String?
    private let contextDebounceSeconds: Double
    private let contextMinimumIntervalSeconds: Double
    private let appPreferences: UserDefaults
    private var demoTask: Task<Void, Never>?
    private var deepTask: Task<Void, Never>?
    private var partialTranscript = ""
    private var workspaceLoadGeneration = 0
    private var codexRefreshGeneration = 0
    private var sessionGeneration = 0
    private var conversationGeneration = 0
    private var agentAuthorizationGeneration = 0
    private var activePartialItemID: String?
    private var partialTexts: [String: String] = [:]
    private var committedPredecessors: [String: String] = [:]
    private var committedRoots: [String] = []
    private var audioDelivery: AudioDeliveryWorker?
    private var transcriptionContinuation: AsyncStream<TranscriptionEvent>.Continuation?
    private var transcriptionTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var postCallTask: Task<Void, Never>?
    private var postCallRunID: UUID?
    private var recordingMaintenanceTask: Task<Void, Never>?
    private var contextDebounceTask: Task<Void, Never>?
    private var contextTask: Task<Void, Never>?
    private var activeContextRunID: UUID?
    private var contextPending = false
    private var contextManualRefresh = false
    private var contextLifecycleGeneration = 0
    private var lastContextStartedAt: Date?
    private var activeInvestigationIDs: Set<UUID> = []
    private var investigationTasks: [UUID: Task<Void, Never>] = [:]
    private struct InvestigationProvenance {
        let model: String?
        let createdAt: Date
    }
    private var investigationProvenance: [UUID: InvestigationProvenance] = [:]
    private var didRestoreWorkspace = false
    private var sessionCreatedAt = Date()
    private var sessionRevision = 0
    private var savedSessionRevision = 0
    private var transcriptRevision = 0
    private var contextTranscriptRevision: Int?
    private var contextFindingModel: String?
    private var persistenceTask: Task<Void, Never>?
    private var persistenceRunID: UUID?
    private var persistenceDebounceTask: Task<Void, Never>?
    private var captureSessionID = UUID()
    private var activeRecordingSessionID: UUID?
    private var liveCaptureEntryIDs: Set<String> = []
    private var postCallContextTarget: (sessionID: UUID, transcriptRevision: Int, sessionGeneration: Int)?
    private var activeSessionWorkspacePath: String?
    private var activeSessionWorkspaceName = ""
    private var sessionPausedForHistory = false
    private var isApplyingSavedSession = false

    /// Production initializer. The host app supplies the platform audio capture and secret storage.
    public init(capture: any AudioCaptureManaging, credentialStore store: any TranscriptionCredentialStore) {
        callConsentDefaults = .standard
        appPreferences = .standard
        contextGuidance = ContextGuidance.load(from: .standard)
        contextLimits = ContextRunLimits.load(from: .standard)
        contextEffort = ReasoningEffort.load(from: .standard, key: ReasoningEffort.contextPreferenceKey)
        investigationEffort = ReasoningEffort.load(from: .standard, key: ReasoningEffort.investigationPreferenceKey)
        temporaryRecordingEnabled = UserDefaults.standard.object(forKey: "temporaryRecordingEnabled") as? Bool ?? true
        batchTranscriptionModel = UserDefaults.standard.string(forKey: "batchTranscriptionModel") ?? ""
        callAgentsEnabled = UserDefaults.standard.bool(forKey: "callAgentsEnabled")
        self.capture = capture
        realtime = RecoveringTranscriptionClient()
        credentialStore = store
        launchAPIKey = Self.environmentAPIKey()
        requiresOpenAIKeyForAgents = true
        modelSelectionStore = ModelSelectionStore()
        contextModel = modelSelectionStore.preferredContextModel ?? ""
        deepModel = modelSelectionStore.preferredPassageModel ?? ""
        contextDebounceSeconds = 2
        contextMinimumIntervalSeconds = 10
        hasSavedTranscriptionCredential = (try? store.load()) != nil
        consentStore = WorkspaceConsentStore()
        let recentStore = RecentWorkspaceStore()
        recentWorkspaceStore = recentStore
        recentWorkspaces = recentStore.availableWorkspaces()
        sessionStore = LocalSessionStore()
        let recordings = AudioRecordingStore()
        recordingStore = recordings
        let keyProvider = OpenAIAPIKeyProvider(credentialStore: store, environmentKey: launchAPIKey)
        agentCoordinator = OpenAIConversationAgent(apiKeyProvider: { try await keyProvider.load() })
        postCallCoordinator = PostCallTranscriptionCoordinator(
            transcriber: OpenAIBatchAudioTranscriber(apiKey: { try await keyProvider.load() }),
            checkpointStore: JSONPostCallTranscriptionCheckpointStore(directory: recordings.checkpointRootURL)
        )
    }

    init(
        codexRuntime: any CodexAppServerRuntime,
        userDefaults: UserDefaults,
        credentialStore: any TranscriptionCredentialStore = EmptyTranscriptionCredentialStore(),
        launchAPIKey: String? = nil,
        sessionStore: (any SessionStoring)? = nil,
        recordingStore: AudioRecordingStore? = nil,
        postCallCoordinator: PostCallTranscriptionCoordinator? = nil,
        conversationAgents: (any ConversationAgentManaging)? = nil,
        contextDebounceSeconds: Double = 2,
        contextMinimumIntervalSeconds: Double = 10
    ) {
        capture = UnavailableAudioCapture()
        realtime = RecoveringTranscriptionClient()
        self.credentialStore = credentialStore
        self.launchAPIKey = launchAPIKey
        callConsentDefaults = userDefaults
        appPreferences = userDefaults
        contextGuidance = ContextGuidance.load(from: userDefaults)
        contextLimits = ContextRunLimits.load(from: userDefaults)
        contextEffort = ReasoningEffort.load(from: userDefaults, key: ReasoningEffort.contextPreferenceKey)
        investigationEffort = ReasoningEffort.load(from: userDefaults, key: ReasoningEffort.investigationPreferenceKey)
        temporaryRecordingEnabled = userDefaults.object(forKey: "temporaryRecordingEnabled") as? Bool ?? true
        batchTranscriptionModel = userDefaults.string(forKey: "batchTranscriptionModel") ?? ""
        callAgentsEnabled = userDefaults.bool(forKey: "callAgentsEnabled")
        requiresOpenAIKeyForAgents = false
        modelSelectionStore = ModelSelectionStore(userDefaults: userDefaults)
        contextModel = modelSelectionStore.preferredContextModel ?? ""
        deepModel = modelSelectionStore.preferredPassageModel ?? ""
        self.sessionStore = sessionStore ?? InMemorySessionStore()
        self.recordingStore = recordingStore
        self.postCallCoordinator = postCallCoordinator
        self.contextDebounceSeconds = contextDebounceSeconds
        self.contextMinimumIntervalSeconds = contextMinimumIntervalSeconds
        hasSavedTranscriptionCredential = (try? credentialStore.load()) != nil
        consentStore = WorkspaceConsentStore(userDefaults: userDefaults)
        let recentStore = RecentWorkspaceStore(userDefaults: userDefaults)
        recentWorkspaceStore = recentStore
        recentWorkspaces = recentStore.availableWorkspaces()
        agentCoordinator = conversationAgents ?? AgentCoordinator(runtime: codexRuntime)
    }

    init(
        codexRuntime: any CodexAppServerRuntime,
        userDefaults: UserDefaults,
        credentialStore: any TranscriptionCredentialStore = EmptyTranscriptionCredentialStore(),
        launchAPIKey: String? = nil,
        capture: any AudioCaptureManaging,
        realtime: any RealtimeTranscribing,
        sessionStore: (any SessionStoring)? = nil,
        recordingStore: AudioRecordingStore? = nil,
        postCallCoordinator: PostCallTranscriptionCoordinator? = nil,
        conversationAgents: (any ConversationAgentManaging)? = nil,
        contextDebounceSeconds: Double = 2,
        contextMinimumIntervalSeconds: Double = 10
    ) {
        self.capture = capture
        self.realtime = realtime
        self.credentialStore = credentialStore
        self.launchAPIKey = launchAPIKey
        callConsentDefaults = userDefaults
        appPreferences = userDefaults
        contextGuidance = ContextGuidance.load(from: userDefaults)
        contextLimits = ContextRunLimits.load(from: userDefaults)
        contextEffort = ReasoningEffort.load(from: userDefaults, key: ReasoningEffort.contextPreferenceKey)
        investigationEffort = ReasoningEffort.load(from: userDefaults, key: ReasoningEffort.investigationPreferenceKey)
        temporaryRecordingEnabled = userDefaults.object(forKey: "temporaryRecordingEnabled") as? Bool ?? true
        batchTranscriptionModel = userDefaults.string(forKey: "batchTranscriptionModel") ?? ""
        callAgentsEnabled = userDefaults.bool(forKey: "callAgentsEnabled")
        requiresOpenAIKeyForAgents = false
        modelSelectionStore = ModelSelectionStore(userDefaults: userDefaults)
        contextModel = modelSelectionStore.preferredContextModel ?? ""
        deepModel = modelSelectionStore.preferredPassageModel ?? ""
        self.sessionStore = sessionStore ?? InMemorySessionStore()
        self.recordingStore = recordingStore
        self.postCallCoordinator = postCallCoordinator
        self.contextDebounceSeconds = contextDebounceSeconds
        self.contextMinimumIntervalSeconds = contextMinimumIntervalSeconds
        hasSavedTranscriptionCredential = (try? credentialStore.load()) != nil
        consentStore = WorkspaceConsentStore(userDefaults: userDefaults)
        let recentStore = RecentWorkspaceStore(userDefaults: userDefaults)
        recentWorkspaceStore = recentStore
        recentWorkspaces = recentStore.availableWorkspaces()
        agentCoordinator = conversationAgents ?? AgentCoordinator(runtime: codexRuntime)
    }

    public var hasConversation: Bool {
        !transcriptEntries.isEmpty || contextFinding != nil || !investigations.isEmpty
    }

    public var displayedTranscriptEntries: [TranscriptEntry] {
        showsPostCallTranscript || postCallTranscriptEntries.isEmpty ? transcriptEntries : postCallTranscriptEntries
    }

    public func setTemporaryRecordingEnabled(_ enabled: Bool) {
        temporaryRecordingEnabled = enabled
        appPreferences.set(enabled, forKey: "temporaryRecordingEnabled")
    }

    @discardableResult
    public func saveContextGuidance(_ text: String) -> Bool {
        guard let guidance = ContextGuidance.validated(text) else { return false }
        contextGuidance = guidance
        appPreferences.set(guidance, forKey: ContextGuidance.preferenceKey)
        return true
    }

    public func resetContextGuidance() {
        appPreferences.removeObject(forKey: ContextGuidance.preferenceKey)
        contextGuidance = ContextGuidance.defaultText
    }

    @discardableResult
    public func saveContextLimits(_ limits: ContextRunLimits) -> Bool {
        guard limits.isValid, let data = try? JSONEncoder().encode(limits) else { return false }
        contextLimits = limits
        appPreferences.set(data, forKey: ContextRunLimits.preferenceKey)
        return true
    }

    public func resetContextLimits() {
        appPreferences.removeObject(forKey: ContextRunLimits.preferenceKey)
        contextLimits = .defaults
    }

    public func setBatchTranscriptionModel(_ model: String) {
        batchTranscriptionModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        appPreferences.set(batchTranscriptionModel, forKey: "batchTranscriptionModel")
    }

    public func retryPostCallReview(userInitiated: Bool = false) {
        guard !isDemo, !isStopping, !isResetting, !phase.isActive, let sessionID = activeSessionID,
              let recordingStore, let postCallCoordinator, !postCallRecordingIDs.isEmpty else { return }
        guard !batchTranscriptionModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            postCallStatus = "needs_setup"
            postCallMessage = "Choose a compatible batch transcription model in Settings."
            recordSessionMutation(immediate: true)
            return
        }
        guard canRunAgents else {
            postCallStatus = "needs_setup"
            postCallMessage = "Enable Context agents and choose a Context model to regenerate the final Context before audio is deleted."
            recordSessionMutation(immediate: true)
            return
        }
        postCallTask?.cancel()
        let runID = UUID()
        postCallRunID = runID
        let capturedGeneration = conversationGeneration
        let capturedSessionGeneration = sessionGeneration
        let recordingIDs = postCallRecordingIDs
        let model = batchTranscriptionModel
        postCallStatus = "transcribing"
        postCallMessage = nil
        recordSessionMutation(immediate: true)
        postCallTask = Task { [weak self] in
            do {
                var finalized: [TranscriptEntry] = []
                var coverageGaps: [AudioRecordingGap] = []
                var captureComplete = true
                for recordingID in recordingIDs {
                    try Task.checkCancellation()
                    let manifest = try await recordingStore.manifest(sessionID: recordingID)
                    captureComplete = captureComplete && manifest.isComplete
                    guard manifest.isComplete || userInitiated else { throw PostCallTranscriptionError.incompleteRecording }
                    let result = try await postCallCoordinator.transcribe(
                        manifest: manifest,
                        sessionID: recordingID,
                        transcriptSessionID: sessionID,
                        chunkURL: { chunk in recordingStore.chunkURL(for: chunk, in: manifest) },
                        model: model,
                        allowRetryUncertain: userInitiated,
                        allowIncomplete: userInitiated
                    )
                    finalized.append(contentsOf: result.entries)
                    coverageGaps.append(contentsOf: result.coverageGaps)
                    captureComplete = captureComplete && result.captureComplete
                }
                guard finalized.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                    throw AppModelPostCallError.noRecognizedSpeech
                }
                guard let self, !Task.isCancelled, self.postCallRunID == runID, self.conversationGeneration == capturedGeneration,
                      self.sessionGeneration == capturedSessionGeneration,
                      self.activeSessionID == sessionID else { return }
                guard self.batchTranscriptionModel == model else {
                    self.postCallStatus = "pending"
                    self.postCallMessage = "The selected post-call model changed during this review. Retry to use the newly selected model."
                    self.recordSessionMutation(immediate: true)
                    self.postCallRunID = nil
                    self.postCallTask = nil
                    return
                }
                let pendingLiveIDs = self.postCallLiveEntryIDs
                let currentLiveEntries = self.transcriptEntries.filter { pendingLiveIDs.contains($0.id) }
                if self.postCallTranscriptEntries.isEmpty {
                    self.postCallTranscriptEntries = currentLiveEntries.isEmpty ? self.transcriptEntries : currentLiveEntries
                } else if !currentLiveEntries.isEmpty {
                    let oldLiveIDs = Set(self.postCallTranscriptEntries.map(\.id))
                    self.postCallTranscriptEntries.append(contentsOf: currentLiveEntries.filter { !oldLiveIDs.contains($0.id) })
                }
                let replacedPrefixes = recordingIDs.map { "postcall:\(sessionID.uuidString.lowercased()):\($0.uuidString.lowercased()):" }
                let previousReviewed = self.transcriptEntries.filter { entry in
                    !pendingLiveIDs.contains(entry.id) && !replacedPrefixes.contains(where: { entry.id.hasPrefix($0) })
                }
                let knownIDs = Set(previousReviewed.map(\.id))
                self.transcriptEntries = previousReviewed + finalized.filter { !knownIDs.contains($0.id) }
                self.transcriptEntries.sort { $0.timestamp < $1.timestamp }
                self.transcriptRevision += 1
                self.postCallRevisionID = UUID()
                self.showsPostCallTranscript = true
                self.contextFinding = nil
                self.contextUpdatedAt = nil
                self.contextTranscriptRevision = nil
                self.contextFindingModel = nil
                self.contextPending = true
                self.postCallStatus = "context_pending"
                self.postCallHasCoverageGaps = !coverageGaps.isEmpty || !captureComplete
                self.postCallContextTarget = (sessionID, self.transcriptRevision, self.sessionGeneration)
                self.postCallMessage = coverageGaps.isEmpty && captureComplete
                    ? "Batch transcript ready. Context is being regenerated from this transcript."
                    : "Batch transcript is partial with \(coverageGaps.count) known gap(s). Context is being regenerated from available audio; recording will be retained."
                self.recordSessionMutation(immediate: true)
                guard await self.flushPersistence() else {
                    self.postCallStatus = "failed"
                    self.postCallMessage = "Final transcript could not be saved; the recording is retained. Retry Save, then review again."
                    self.recordSessionMutation(immediate: true)
                    return
                }
                guard self.activeSessionID == sessionID, self.postCallRunID == runID,
                      self.sessionGeneration == capturedSessionGeneration else { return }
                self.scheduleContextUpdate(after: .zero, allowIdle: true)
            } catch {
                guard let self, !Task.isCancelled, self.postCallRunID == runID, self.conversationGeneration == capturedGeneration,
                      self.sessionGeneration == capturedSessionGeneration,
                      self.activeSessionID == sessionID else { return }
                self.postCallStatus = "failed"
                self.postCallMessage = error.localizedDescription
                self.recordSessionMutation(immediate: true)
            }
            guard let self, self.activeSessionID == sessionID, self.postCallRunID == runID else { return }
            self.postCallTask = nil
        }
    }

    public func deleteTemporaryRecordingNow() {
        guard activeRecordingSessionID == nil else {
            postCallMessage = "Stop listening before deleting the temporary recording."
            return
        }
        guard let recordingStore else { return }
        let activeReview = postCallTask
        activeReview?.cancel()
        postCallRunID = nil
        let ids = postCallRecordingIDs
        let sessionID = activeSessionID
        Task { [weak self] in
            do {
                await activeReview?.value
                for id in ids { try await recordingStore.delete(sessionID: id) }
                guard let self, self.activeSessionID == sessionID else { return }
                self.postCallTask = nil
                self.postCallRecordingIDs = []
                self.postCallAudioExpiresAt = nil
                self.postCallStatus = "deleted"
                self.postCallMessage = "Temporary recording deleted."
                self.recordSessionMutation(immediate: true)
            } catch {
                guard let self, self.activeSessionID == sessionID else { return }
                self.postCallMessage = "Recording deletion failed: \(error.localizedDescription)"
                self.recordSessionMutation(immediate: true)
            }
        }
    }

    public func setKeepRecordingUntilReviewed(_ keep: Bool) {
        postCallKeepUntilReviewed = keep
        recordSessionMutation(immediate: true)
        if !keep, postCallStatus == "retained" {
            deleteTemporaryRecordingNow()
        }
    }

    private func finishPostCallIfContextSaved(sessionID: UUID, sessionGeneration: Int, recordingIDs: [UUID], expectedRevision: Int) async {
        guard activeSessionID == sessionID, postCallStatus == "context_pending", transcriptRevision == expectedRevision,
              self.sessionGeneration == sessionGeneration, contextTranscriptRevision == expectedRevision, contextFinding != nil else { return }
        guard await flushPersistence() else { return }
        guard activeSessionID == sessionID, postCallStatus == "context_pending",
              self.sessionGeneration == sessionGeneration, transcriptRevision == expectedRevision,
              contextTranscriptRevision == expectedRevision else { return }
        if postCallKeepUntilReviewed {
            postCallStatus = "retained"
            postCallLiveEntryIDs = []
            postCallMessage = "Reviewed transcript and matching Context are saved. The temporary recording is retained until you delete it or the 24-hour expiry."
            recordSessionMutation(immediate: true)
            _ = await flushPersistence()
            return
        }
        if postCallHasCoverageGaps {
            postCallStatus = "partial"
            postCallLiveEntryIDs = []
            postCallMessage = "Post-call transcript and Context were saved with coverage gaps. Temporary audio is retained for inspection and expires after 24 hours."
            recordSessionMutation(immediate: true)
            _ = await flushPersistence()
            return
        }
        guard let recordingStore else { return }
        do {
            for id in recordingIDs { try await recordingStore.markAnalysisSavedAndDelete(sessionID: id) }
            guard activeSessionID == sessionID, self.sessionGeneration == sessionGeneration,
                  postCallStatus == "context_pending", transcriptRevision == expectedRevision,
                  contextTranscriptRevision == expectedRevision else { return }
            postCallRecordingIDs.removeAll { recordingIDs.contains($0) }
            postCallLiveEntryIDs = []
            postCallAudioExpiresAt = nil
            postCallStatus = "complete"
            postCallMessage = "Post-call transcript and matching Context are saved. Temporary audio was deleted."
            recordingStatus = "Temporary recording deleted after saved review."
            recordSessionMutation(immediate: true)
            _ = await flushPersistence()
        } catch {
            guard activeSessionID == sessionID, self.sessionGeneration == sessionGeneration else { return }
            postCallStatus = "failed"
            postCallMessage = "Transcript and Context are saved, but audio deletion failed: \(error.localizedDescription)"
            recordSessionMutation(immediate: true)
        }
    }

    var isPersistenceClean: Bool {
        activeSessionID == nil || (savedSessionRevision >= sessionRevision && persistenceTask == nil)
    }

    public var canRelinkWorkspace: Bool {
        sessionPausedForHistory && activeSessionWorkspacePath != nil && workspaceURL == nil && !phase.isActive && !isStopping && !isResetting
    }

    public var isCallOnly: Bool { workspaceURL == nil && activeSessionWorkspacePath == nil }
    public var canStartListening: Bool { (isCallOnly || workspaceURL != nil) && hasTranscriptionCredential && !isLoadingWorkspace }

    public var isInvestigating: Bool { !activeInvestigationIDs.isEmpty }

    public var canUseWorkspaceAgents: Bool {
        !isDemo && (isCallOnly ? callAgentsEnabled : (workspaceURL != nil && hasAgentConsent)) && agentCoordinator != nil
            && (!requiresOpenAIKeyForAgents || hasTranscriptionCredential)
    }

    public var canRunAgents: Bool { canUseWorkspaceAgents && !contextModel.isEmpty }
    public var canInvestigate: Bool { canUseWorkspaceAgents && !deepModel.isEmpty }

    public var hasTranscriptionCredential: Bool {
        launchAPIKey != nil || hasSavedTranscriptionCredential
    }

    public var usesEnvironmentCredential: Bool {
        launchAPIKey != nil
    }

    public func saveTranscriptionAPIKey(_ apiKey: String) -> Bool {
        let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            credentialMessage = "Enter an API key first."
            return false
        }
        do {
            let previous = try? credentialStore.load()
            try credentialStore.save(value)
            hasSavedTranscriptionCredential = true
            credentialMessage = "Saved securely in Keychain."
            if previous != value { invalidateAgentCredential() }
            return true
        } catch {
            credentialMessage = error.localizedDescription
            return false
        }
    }

    public func removeTranscriptionAPIKey() {
        do {
            let hadKey = (try? credentialStore.load()) != nil
            try credentialStore.delete()
            hasSavedTranscriptionCredential = false
            credentialMessage = "Removed from Keychain."
            if hadKey { invalidateAgentCredential() }
        } catch {
            credentialMessage = error.localizedDescription
        }
    }

    public func startLive() async {
        guard !isStopping, !isResetting, !phase.isActive else { return }
        guard !isDemo else {
            workspaceMessage = "Start a new conversation before switching from the demo to live audio."
            return
        }
        guard let apiKey = resolvedTranscriptionAPIKey() else {
            phase = .failed("Add an OpenAI API key under Live transcription, or try the demo meeting.")
            return
        }
        guard isCallOnly || workspaceURL != nil else {
            phase = .failed("Relink this conversation’s saved folder before resuming.")
            return
        }

        sessionPausedForHistory = false
        await interruptPostCallForTransition()
        beginCaptureSession()
        let generation = sessionGeneration
        phase = .connecting
        isDemo = false

        do {
            let (events, eventContinuation) = AsyncStream<TranscriptionEvent>.makeStream(
                bufferingPolicy: .bufferingOldest(128)
            )
            transcriptionContinuation = eventContinuation
            transcriptionTask = Task { [weak self] in
                for await event in events {
                    guard let self, !Task.isCancelled else { return }
                    await self.handle(event, generation: generation)
                }
            }
            try await realtime.connect(
                apiKey: apiKey,
                model: transcriptionModel,
                context: "A work meeting. Transcribe product names, people, projects, and technical terms accurately."
            ) { [weak self] event in
                if case .dropped = eventContinuation.yield(event) {
                    Task { @MainActor in
                        await self?.failLiveSession("Transcription events arrived faster than they could be processed.", generation: generation)
                    }
                }
            }

            guard sessionGeneration == generation, phase == .connecting else {
                return
            }

            let realtime = self.realtime
            let delivery = AudioDeliveryWorker(send: { data in
                await realtime.send(audioPCM16: data)
            }, onOverflow: { [weak self] in
                Task { @MainActor in
                    await self?.failLiveSession("Audio processing fell more than two seconds behind. Listening stopped; part of the transcript may be missing.", generation: generation)
                }
            })
            audioDelivery = delivery
            if temporaryRecordingEnabled, let recordingStore {
                let recordingID = UUID()
                do {
                    let expectedSources: Set<AudioRecordingSource> = switch sourceMode {
                    case .system: [.system]
                    case .microphone: [.microphone]
                    case .both: [.system, .microphone]
                    }
                    try await recordingStore.begin(sessionID: recordingID, expectedSources: expectedSources)
                    activeRecordingSessionID = recordingID
                    postCallRecordingIDs.append(recordingID)
                    postCallStatus = "recording"
                    postCallMessage = nil
                    postCallAudioExpiresAt = Date().addingTimeInterval(AudioRecordingStore.retention)
                    recordingStatus = "Temporary recording is active · expires in 24 hours"
                    recordSessionMutation(immediate: true)
                } catch {
                    activeRecordingSessionID = nil
                    recordingStatus = "Temporary recording could not start: \(error.localizedDescription)"
                }
            }
            try await capture.start(mode: sourceMode, audioHandler: { data in
                delivery.enqueue(data)
            }, errorHandler: { [weak self] message in
                Task { @MainActor in await self?.failLiveSession(message, generation: generation) }
            }, recordingSessionID: activeRecordingSessionID, recordingHandler: { [recordingStore] id, source, data, time in
                recordingStore?.enqueue(sessionID: id, source: source, pcm16: data, presentationTime: time)
            })
            guard sessionGeneration == generation, phase == .connecting else {
                return
            }
            phase = .listening
            if contextPending { scheduleContextUpdate(after: .zero) }
        } catch { await failLiveSession(error.localizedDescription, generation: generation) }
    }

    func resolvedTranscriptionAPIKey() -> String? {
        if let launchAPIKey { return launchAPIKey }
        return try? credentialStore.load()
    }

    private static func environmentAPIKey() -> String? {
        guard let value = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else { return nil }
        return value
    }

    public func startDemo() {
        guard !isStopping, !isResetting, !phase.isActive else { return }
        guard !hasConversation else {
            workspaceMessage = "Start a new conversation before beginning the demo."
            return
        }
        beginCaptureSession()
        let generation = sessionGeneration
        isDemo = true
        phase = .listening

        let utterances = [
            "Before we get into the Acme renewal, can we confirm the SSO exception?",
            "The SAML role mapping still needs to land before Friday.",
            "They also asked what the EU data residency migration date looks like.",
            "Could someone investigate whether the pricing approval changes for a multi-year renewal?"
        ]

        demoTask = Task { [weak self] in
            for utterance in utterances {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                guard let self, self.sessionGeneration == generation else { return }
                self.ingestDemo(utterance, generation: generation)
            }
        }
    }

    public func stop() async {
        if let stopTask {
            await stopTask.value
            return
        }
        sessionGeneration += 1
        let generation = sessionGeneration
        isStopping = true
        phase = .idle
        demoTask?.cancel()
        demoTask = nil
        contextLifecycleGeneration += 1
        contextDebounceTask?.cancel()
        contextDebounceTask = nil
        contextTask?.cancel()
        if activeContextRunID != nil { contextPending = true }
        activeContextRunID = nil
        contextTask = nil
        deepTask?.cancel()
        deepTask = nil
        partialTranscript = ""
        partialTexts = [:]
        activePartialItemID = nil
        let activeInvestigationIDs = self.activeInvestigationIDs
        self.activeInvestigationIDs.removeAll()
        for id in activeInvestigationIDs {
            investigationTasks[id]?.cancel()
            investigationTasks[id] = nil
            if let index = investigations.firstIndex(where: { $0.id == id }) {
                investigations[index].activity = .failed("Stopped")
            }
        }
        mediumActivity = .idle
        if !activeInvestigationIDs.isEmpty { recordSessionMutation(immediate: true) }
        persistenceDebounceTask?.cancel(); persistenceDebounceTask = nil
        if savedSessionRevision < sessionRevision { startPersistenceLoop() }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.finishStopping(generation: generation, activeInvestigationIDs: activeInvestigationIDs)
        }
        stopTask = task
        await task.value
    }

    public func newConversation() async {
        guard !isResetting else { return }
        isResetting = true
        defer { isResetting = false }
        await interruptPostCallForTransition()
        await stop()
        await interruptPostCallForTransition()
        guard await flushPersistence() else { return }
        conversationGeneration += 1
        await agentCoordinator?.resetConversation()
        clearActiveConversation()
    }

    public func loadSessionHistory() async {
        guard !isLoadingHistory else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            sessionHistory = try await sessionStore.list()
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    public func openSession(id: UUID) async -> Bool {
        guard !isResetting else { return false }
        isResetting = true
        defer { isResetting = false }
        await interruptPostCallForTransition()
        workspaceLoadGeneration += 1
        codexRefreshGeneration += 1
        didRestoreWorkspace = true
        isLoadingWorkspace = false
        isLoadingCodex = false
        let loaded: SessionLoadResult
        do {
            loaded = try await sessionStore.load(id: id)
            guard loaded.session.schemaVersion == SavedSession.currentSchemaVersion else {
                throw SessionStoreError.unsupportedSchemaVersion(id: id, version: loaded.session.schemaVersion)
            }
        } catch {
            persistenceError = error.localizedDescription
            return false
        }

        await stop()
        await interruptPostCallForTransition()
        guard await flushPersistence() else { return false }
        if id == activeSessionID {
            sessionPausedForHistory = true
            codexMessage = "Session paused. Resume when ready."
            return true
        }

        // Invalidate any startup workspace load or discovery before applying the stored call.
        workspaceLoadGeneration += 1
        codexRefreshGeneration += 1
        didRestoreWorkspace = true
        isLoadingWorkspace = false
        isLoadingCodex = false
        conversationGeneration += 1
        contextLifecycleGeneration += 1
        contextDebounceTask?.cancel(); contextDebounceTask = nil
        contextTask?.cancel(); contextTask = nil
        activeContextRunID = nil
        contextPending = false
        contextManualRefresh = false

        let record = loaded.session
        isApplyingSavedSession = true
        activeSessionID = record.id
        sessionTitle = record.title.isEmpty ? "Untitled conversation" : record.title
        sessionCreatedAt = record.createdAt
        sessionRevision = record.revision
        savedSessionRevision = record.revision
        transcriptRevision = record.transcriptRevision ?? record.transcript.filter(\.isFinal).count
        contextTranscriptRevision = record.contextTranscriptRevision
        contextFindingModel = record.contextFindingModel
        sourceMode = AudioSourceMode(rawValue: record.sourceMode) ?? .microphone
        transcriptionModel = TranscriptionModel(rawValue: record.transcriptionModel) ?? .live
        contextModel = record.contextModel
        deepModel = record.investigationModel
        transcriptEntries = record.transcript.map(\.transcriptEntry)
        transcript = transcriptEntries.last(where: { !$0.text.isEmpty })?.text ?? ""
        contextFinding = record.context?.agentFinding
        postCallTranscriptEntries = record.postCallTranscript?.map(\.transcriptEntry) ?? []
        postCallRevisionID = record.postCallRevisionID
        postCallStatus = record.postCallStatus
        postCallMessage = record.postCallMessage
        postCallAudioExpiresAt = record.postCallAudioExpiresAt
        postCallRecordingIDs = record.postCallRecordingIDs ?? []
        postCallLiveEntryIDs = Set(record.postCallLiveEntryIDs ?? [])
        postCallHasCoverageGaps = record.postCallHasCoverageGaps ?? false
        postCallKeepUntilReviewed = record.postCallKeepUntilReviewed ?? false
        showsPostCallTranscript = record.postCallRevisionID != nil
        batchTranscriptionModel = record.postCallModel ?? batchTranscriptionModel
        contextUpdatedAt = record.contextUpdatedAt
        investigationProvenance = Dictionary(uniqueKeysWithValues: record.investigations.map {
            ($0.id, InvestigationProvenance(model: $0.model, createdAt: $0.createdAt ?? record.createdAt))
        })
        investigations = record.investigations.map { saved in
            var resumable = saved
            if saved.status == "working" {
                resumable = SavedInvestigation(
                    id: saved.id, selectionText: saved.selectionText, entryIDs: saved.entryIDs,
                    question: saved.question, status: "failed", statusMessage: "Interrupted when Murmur closed.",
                    finding: saved.finding, model: saved.model, createdAt: saved.createdAt
                )
            }
            return resumable.passageInvestigation
        }
        agentFindings = ([contextFinding].compactMap { $0 } + investigations.compactMap(\.finding))
        isDemo = record.isDemo
        activeSessionWorkspacePath = record.workspacePath
        activeSessionWorkspaceName = record.workspaceName
        workspaceName = record.workspaceName.isEmpty ? "Call only" : record.workspaceName
        workspaceURL = nil
        workspaceDocumentCount = 0
        workspaceMessage = nil
        hasAgentConsent = false
        codexModels = []
        codexSkills = []
        codexMessage = "Session opened paused. Resume when ready."
        persistenceError = nil
        persistenceStatus = "Saved"
        sessionPausedForHistory = true
        phase = .idle
        mediumActivity = contextFinding.map { .completed($0.title) } ?? .idle
        deepActivity = .idle
        isApplyingSavedSession = false

        if let savedPath = record.workspacePath {
            let folder = URL(fileURLWithPath: savedPath, isDirectory: true)
            if FileManager.default.fileExists(atPath: folder.path) {
                let loadGeneration = workspaceLoadGeneration
                do {
                    let loadedWorkspace = try await workspaceLoader.load(folder: folder)
                    guard activeSessionID == record.id, workspaceLoadGeneration == loadGeneration else { return false }
                    workspaceURL = folder.standardizedFileURL.resolvingSymlinksInPath()
                    workspaceName = loadedWorkspace.name
                    workspaceDocumentCount = loadedWorkspace.index.documentCount
                    if let openedRoot = workspaceURL {
                        hasAgentConsent = consentStore.hasConsent(for: openedRoot)
                        recentWorkspaces = recentWorkspaceStore.remember(openedRoot)
                    }
                    workspaceMessage = nil
                    // No Codex discovery occurs while reopening a paused session.
                } catch {
                    workspaceMessage = "Saved workspace is unavailable: \(error.localizedDescription)"
                    workspaceURL = nil
                    hasAgentConsent = false
                }
            } else {
                workspaceMessage = "Saved workspace is missing. Choose it before resuming."
            }
        } else {
            workspaceMessage = "Call-only session. No local folders are accessible."
        }
        if loaded.recoveredFromBackup { persistenceStatus = "Recovered from backup" }
        await loadSessionHistory()
        return true
    }

    public func renameSession(id: UUID, title: String) async {
        guard !isResetting else { return }
        isResetting = true
        defer { isResetting = false }
        let cleanedTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !cleanedTitle.isEmpty else { persistenceError = "Enter a session title."; return }
        if id == activeSessionID {
            sessionTitle = cleanedTitle
            recordSessionMutation(immediate: true)
            _ = await flushPersistence()
            return
        }
        do {
            var record = try await sessionStore.load(id: id).session
            guard record.schemaVersion == SavedSession.currentSchemaVersion else {
                throw SessionStoreError.unsupportedSchemaVersion(id: id, version: record.schemaVersion)
            }
            record.revision += 1
            record.title = cleanedTitle
            record.updatedAt = Date()
            try await sessionStore.save(record)
            await loadSessionHistory()
        } catch { persistenceError = error.localizedDescription }
    }

    public func deleteSession(id: UUID) async -> Bool {
        guard !isResetting else { return false }
        isResetting = true
        defer { isResetting = false }
        if id == activeSessionID { await interruptPostCallForTransition() }
        if id == activeSessionID {
            await stop()
            await interruptPostCallForTransition()
            persistenceDebounceTask?.cancel(); persistenceDebounceTask = nil
            if let persistenceTask { await persistenceTask.value }
            // The save worker has settled before the tombstone is written.
            persistenceRunID = nil
            persistenceTask = nil
        }
        do {
            if let recordingStore {
                let savedIDs: [UUID]
                if id == activeSessionID { savedIDs = postCallRecordingIDs }
                else { savedIDs = (try? await sessionStore.load(id: id).session.postCallRecordingIDs) ?? [] }
                for recordingID in savedIDs { try await recordingStore.delete(sessionID: recordingID) }
            }
            try await sessionStore.delete(id: id)
            if id == activeSessionID { clearActiveConversation() }
            persistenceError = nil
            await loadSessionHistory()
            return true
        } catch {
            persistenceError = error.localizedDescription
            if id == activeSessionID { persistenceStatus = "Save failed" }
            await loadSessionHistory()
            return false
        }
    }

    public func exportSession(id: UUID, format: SessionExportFormat) async throws -> Data {
        if id == activeSessionID {
            return try SessionExporter.data(session: currentSavedSession(), format: format)
        }
        let record = try await sessionStore.load(id: id).session
        guard record.schemaVersion == SavedSession.currentSchemaVersion else {
            throw SessionStoreError.unsupportedSchemaVersion(id: id, version: record.schemaVersion)
        }
        return try SessionExporter.data(session: record, format: format)
    }

    public func retrySave() async {
        guard activeSessionID != nil else { return }
        persistenceError = nil
        sessionRevision = max(sessionRevision, savedSessionRevision) + 1
        persistenceStatus = "Not saved"
        startPersistenceLoop()
        _ = await flushPersistence()
    }

    public func prepareForQuit() async -> Bool {
        guard !isResetting else { return false }
        isResetting = true
        defer { isResetting = false }
        await interruptPostCallForTransition()
        await stop()
        await interruptPostCallForTransition()
        return await flushPersistence()
    }

    private func ensureActiveSession() {
        guard activeSessionID == nil else { return }
        activeSessionID = UUID()
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "d MMM, HH:mm"
        sessionTitle = "Conversation · \(formatter.string(from: Date()))"
        sessionCreatedAt = Date()
        sessionRevision = 0
        savedSessionRevision = 0
        activeSessionWorkspacePath = workspaceURL?.path
        activeSessionWorkspaceName = workspaceURL == nil ? "" : workspaceName
        sessionPausedForHistory = false
        persistenceStatus = "Not saved"
        persistenceError = nil
    }

    private func interruptPostCallForTransition() async {
        if let task = postCallTask {
            task.cancel()
            postCallRunID = nil
            await task.value
            postCallTask = nil
        }
        if postCallContextTarget != nil || postCallStatus == "context_pending" {
            contextLifecycleGeneration += 1
            contextDebounceTask?.cancel(); contextDebounceTask = nil
            contextTask?.cancel(); contextTask = nil
            activeContextRunID = nil
            contextPending = false
            postCallContextTarget = nil
        }
        if postCallStatus == "transcribing" || postCallStatus == "context_pending" {
            postCallStatus = "pending"
            postCallMessage = "Review paused because this conversation was changed. Retry to continue; an interrupted upload may require explicit confirmation."
            recordSessionMutation(immediate: true)
            _ = await flushPersistence()
        }
    }

    private func currentSavedSession() -> SavedSession {
        SavedSession(
            id: activeSessionID ?? UUID(), revision: max(1, sessionRevision), title: sessionTitle,
            createdAt: sessionCreatedAt, updatedAt: Date(), workspacePath: activeSessionWorkspacePath,
            workspaceName: activeSessionWorkspaceName, isDemo: isDemo,
            sourceMode: sourceMode.rawValue, transcriptionModel: transcriptionModel.rawValue,
            contextModel: contextModel, investigationModel: deepModel,
            transcript: transcriptEntries.map(SavedTranscriptEntry.init),
            context: contextFinding.map(SavedFinding.init), contextUpdatedAt: contextUpdatedAt,
            transcriptRevision: transcriptRevision,
            contextTranscriptRevision: contextTranscriptRevision, contextFindingModel: contextFindingModel,
            investigations: investigations.map { investigation in
                let provenance = investigationProvenance[investigation.id]
                return SavedInvestigation(investigation, model: provenance?.model, createdAt: provenance?.createdAt ?? sessionCreatedAt)
            },
            postCallTranscript: postCallTranscriptEntries.isEmpty ? nil : postCallTranscriptEntries.map(SavedTranscriptEntry.init),
            postCallRevisionID: postCallRevisionID, postCallStatus: postCallStatus,
            postCallMessage: postCallMessage, postCallModel: batchTranscriptionModel.isEmpty ? nil : batchTranscriptionModel,
            postCallKeepUntilReviewed: postCallKeepUntilReviewed, postCallAudioExpiresAt: postCallAudioExpiresAt,
            postCallRecordingIDs: postCallRecordingIDs.isEmpty ? nil : postCallRecordingIDs,
            postCallLiveEntryIDs: postCallLiveEntryIDs.isEmpty ? nil : postCallLiveEntryIDs.sorted(),
            postCallHasCoverageGaps: postCallHasCoverageGaps
        )
    }

    private func recordSessionMutation(immediate: Bool) {
        guard activeSessionID != nil else { return }
        let hasPersistableContent = transcriptEntries.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            || contextFinding != nil || !investigations.isEmpty || !postCallRecordingIDs.isEmpty
            || !postCallTranscriptEntries.isEmpty || postCallStatus != nil || savedSessionRevision > 0
        guard hasPersistableContent else { return }
        sessionRevision += 1
        persistenceError = nil
        persistenceStatus = "Not saved"
        if immediate {
            persistenceDebounceTask?.cancel(); persistenceDebounceTask = nil
            startPersistenceLoop()
        } else if persistenceDebounceTask == nil {
            persistenceDebounceTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(0.8))
                guard let self, !Task.isCancelled else { return }
                self.persistenceDebounceTask = nil
                self.startPersistenceLoop()
            }
        }
    }

    private func startPersistenceLoop() {
        guard activeSessionID != nil, persistenceTask == nil else { return }
        let runID = UUID()
        persistenceRunID = runID
        persistenceStatus = "Saving…"
        persistenceTask = Task { [weak self] in await self?.runPersistenceLoop(runID: runID) }
    }

    private func runPersistenceLoop(runID: UUID) async {
        defer {
            if persistenceRunID == runID {
                persistenceTask = nil
                persistenceRunID = nil
            }
        }
        while !Task.isCancelled, persistenceRunID == runID,
              let id = activeSessionID, savedSessionRevision < sessionRevision {
            let capturedRevision = sessionRevision
            var snapshot = currentSavedSession()
            snapshot.revision = capturedRevision
            do {
                try await sessionStore.save(snapshot)
                guard persistenceRunID == runID, activeSessionID == id else { return }
                savedSessionRevision = max(savedSessionRevision, capturedRevision)
                if savedSessionRevision == sessionRevision {
                    persistenceStatus = "Saved"
                    persistenceError = nil
                } else {
                    persistenceStatus = "Saving…"
                }
                updateActiveSummary(from: snapshot)
            } catch {
                guard activeSessionID == id, persistenceRunID == runID else { return }
                persistenceError = error.localizedDescription
                persistenceStatus = "Save failed"
                break
            }
        }
    }

    private func flushPersistence() async -> Bool {
        guard activeSessionID != nil else { return true }
        persistenceDebounceTask?.cancel(); persistenceDebounceTask = nil
        if savedSessionRevision < sessionRevision, persistenceTask == nil {
            persistenceError = nil
            startPersistenceLoop()
        }
        while let task = persistenceTask {
            await task.value
            if savedSessionRevision < sessionRevision && persistenceError != nil { return false }
            if savedSessionRevision < sessionRevision, persistenceTask == nil { startPersistenceLoop() }
        }
        return savedSessionRevision >= sessionRevision && persistenceTask == nil
    }

    private func updateActiveSummary(from record: SavedSession) {
        let preview = record.transcript.last(where: \.isFinal)?.text ?? record.context?.summary ?? ""
        let summary = SessionSummary(id: record.id, title: record.title, createdAt: record.createdAt,
                                     updatedAt: record.updatedAt, preview: String(preview.prefix(240)),
                                     isDemo: record.isDemo)
        sessionHistory.removeAll { $0.id == record.id }
        sessionHistory.insert(summary, at: 0)
    }

    private func clearActiveConversation() {
        workspaceLoadGeneration += 1
        isLoadingWorkspace = false
        conversationGeneration += 1
        activeSessionID = nil
        sessionTitle = "New conversation"
        sessionCreatedAt = Date()
        sessionRevision = 0; savedSessionRevision = 0; transcriptRevision = 0
        contextTranscriptRevision = nil; contextFindingModel = nil
        activeSessionWorkspacePath = nil; activeSessionWorkspaceName = ""
        transcriptEntries = []; transcript = ""; partialTranscript = ""; partialTexts = [:]
        committedPredecessors = [:]; committedRoots = []; activePartialItemID = nil
        contextFinding = nil; contextUpdatedAt = nil; contextMessage = nil
        postCallTranscriptEntries = []; postCallRevisionID = nil; postCallStatus = nil
        postCallMessage = nil; postCallAudioExpiresAt = nil; postCallKeepUntilReviewed = false
        postCallRecordingIDs = []
        postCallLiveEntryIDs = []
        postCallHasCoverageGaps = false
        showsPostCallTranscript = false
        investigations = []; cues = []; agentFindings = []
        investigationProvenance = [:]
        mediumActivity = .idle; deepActivity = .idle; isDemo = false
        contextPending = false; contextManualRefresh = false; sessionPausedForHistory = false
        persistenceStatus = "Not saved"; persistenceError = nil
        workspaceMessage = nil
        workspaceURL = nil; workspaceName = "Call only"; workspaceDocumentCount = 0; hasAgentConsent = false
        stopTask = nil
    }

    public func dismissInvestigation(id: UUID) {
        guard !activeInvestigationIDs.contains(id) else { return }
        investigations.removeAll { $0.id == id }
        investigationProvenance[id] = nil
        recordSessionMutation(immediate: true)
    }

    public func dismissError() {
        if case .failed = phase { phase = .idle }
    }

    public func restoreLastWorkspaceIfNeeded() async {
        await loadSessionHistory()
        startRecordingMaintenance()
        guard activeSessionID == nil else { return }
        guard !didRestoreWorkspace else { return }
        didRestoreWorkspace = true
        recentWorkspaces = recentWorkspaceStore.availableWorkspaces()
        // A new call never inherits filesystem access from the last call.
    }

    private func startRecordingMaintenance() {
        guard recordingMaintenanceTask == nil, let recordingStore else { return }
        recordingMaintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let recovered = try await recordingStore.recoverableSessions()
                    await self?.reconcileRecordingManifests(recovered)
                    try await recordingStore.cleanupExpired()
                } catch {
                    self?.recordRecordingMaintenanceError(error.localizedDescription)
                }
                do { try await Task.sleep(for: .seconds(1_800)) }
                catch { return }
            }
        }
    }

    private func recordRecordingMaintenanceError(_ message: String) {
        recordingStatus = "Temporary recording recovery could not be completed: \(message)"
    }

    private func reconcileRecordingManifests(_ manifests: [AudioRecordingManifest]) async {
        let available = Dictionary(uniqueKeysWithValues: manifests.map { ($0.id, $0) })
        let now = Date()
        for summary in sessionHistory where summary.available {
            guard let loaded = try? await sessionStore.load(id: summary.id) else { continue }
            let ids = loaded.session.postCallRecordingIDs ?? []
            guard !ids.isEmpty else { continue }
            let currentlyWritingID = summary.id == activeSessionID ? activeRecordingSessionID : nil
            let present = ids.filter { available[$0] != nil || $0 == currentlyWritingID }
            let missing = ids.filter { available[$0] == nil && $0 != currentlyWritingID }
            guard !missing.isEmpty || present.contains(where: { available[$0]?.finishedAt != nil && available[$0]?.isComplete == false }) else { continue }
            let isExpectedDeletion = loaded.session.postCallStatus == "complete" || loaded.session.postCallStatus == "deleted"
            let isExpired = loaded.session.postCallAudioExpiresAt.map { $0 <= now } ?? false
            var status = loaded.session.postCallStatus
            var message = loaded.session.postCallMessage
            if !present.isEmpty, present.contains(where: { available[$0]?.isComplete == false }) {
                status = "pending"
                message = "Murmur recovered interrupted or incomplete audio. Choose Analyze available audio to review it; coverage may be incomplete."
            }
            var remaining = present
            if !missing.isEmpty {
                if isExpectedDeletion { remaining = present }
                else if isExpired {
                    status = "expired"
                    message = "Temporary recording expired after its 24-hour limit."
                } else {
                    status = "failed"
                    message = "Some temporary recording files are unavailable. Murmur could not confirm expiry; remaining audio was retained."
                }
            }
            if status == loaded.session.postCallStatus, remaining == ids { continue }
            if summary.id == activeSessionID {
                postCallRecordingIDs = remaining
                postCallStatus = status
                postCallMessage = message
                if remaining.isEmpty && (isExpired || isExpectedDeletion) {
                    postCallAudioExpiresAt = nil
                }
                recordSessionMutation(immediate: true)
            } else {
                var record = loaded.session
                record.revision += 1
                record.postCallRecordingIDs = remaining.isEmpty ? nil : remaining
                record.postCallStatus = status
                record.postCallMessage = message
                if remaining.isEmpty && (isExpired || isExpectedDeletion) {
                    record.postCallAudioExpiresAt = nil
                }
                record.updatedAt = Date()
                try? await sessionStore.save(record)
            }
        }
    }

    public func switchToRecentWorkspace(_ workspace: RecentWorkspace) async {
        guard let folder = recentWorkspaceStore.resolve(workspace) else {
            recentWorkspaces = recentWorkspaceStore.availableWorkspaces()
            workspaceMessage = "That workspace folder is no longer available."
            return
        }
        await loadWorkspace(from: folder)
    }

    public func loadWorkspace(from folder: URL) async {
        guard !isStopping, !isResetting, !phase.isActive else { return }
        let isRelinkingPausedSession = canRelinkWorkspace
        guard !hasConversation || canRelinkWorkspace else {
            workspaceMessage = "Start a new conversation before switching workspaces."
            return
        }
        workspaceLoadGeneration += 1
        let generation = workspaceLoadGeneration
        isLoadingWorkspace = true
        workspaceMessage = nil

        do {
            let loaded = try await workspaceLoader.load(folder: folder)
            guard generation == workspaceLoadGeneration else { return }
            let canonicalFolder = folder.standardizedFileURL.resolvingSymlinksInPath()
            agentAuthorizationGeneration += 1
            workspaceName = loaded.name
            workspaceDocumentCount = loaded.index.documentCount
            workspaceURL = canonicalFolder
            if sessionPausedForHistory {
                activeSessionWorkspacePath = canonicalFolder.path
                activeSessionWorkspaceName = loaded.name
                recordSessionMutation(immediate: true)
            }
            recentWorkspaces = recentWorkspaceStore.remember(canonicalFolder)
            hasAgentConsent = consentStore.hasConsent(for: canonicalFolder)
            codexModels = []
            codexSkills = []
            agentFindings = []
            isLoadingCodex = false
            if hasAgentConsent && !isRelinkingPausedSession {
                Task { @MainActor in await refreshCodex() }
            } else if isRelinkingPausedSession {
                codexMessage = "Session remains paused. Refresh OpenAI models or resume when ready."
            } else {
                codexMessage = "Refresh model IDs at any time. Allow workspace agents before making file-aware requests."
            }
        } catch {
            guard generation == workspaceLoadGeneration else { return }
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory)
                || !isDirectory.boolValue {
                recentWorkspaces = recentWorkspaceStore.remove(folder)
            }
            workspaceMessage = error.localizedDescription
        }

        if generation == workspaceLoadGeneration { isLoadingWorkspace = false }
    }

    public func useCallOnly() {
        guard !hasConversation, !phase.isActive, !isStopping, !isResetting else { return }
        workspaceLoadGeneration += 1
        codexRefreshGeneration += 1
        isLoadingWorkspace = false; isLoadingCodex = false
        workspaceURL = nil; activeSessionWorkspacePath = nil; activeSessionWorkspaceName = ""
        workspaceName = "Call only"; workspaceDocumentCount = 0; workspaceMessage = nil
        hasAgentConsent = false
        agentAuthorizationGeneration += 1
    }

    public func enableCallAgents() {
        callAgentsEnabled = true
        callConsentDefaults.set(true, forKey: "callAgentsEnabled")
        agentAuthorizationGeneration += 1
        if contextPending { scheduleContextUpdate(after: .zero) }
    }

    public func disableCallAgents() {
        callAgentsEnabled = false
        callConsentDefaults.set(false, forKey: "callAgentsEnabled")
        if isCallOnly { cancelAuthorizedAgents() }
    }

    public func grantAgentConsent() {
        guard let workspaceURL else { return }
        consentStore.grantConsent(for: workspaceURL)
        agentAuthorizationGeneration += 1
        hasAgentConsent = true
    }

    public func revokeAgentConsent() {
        guard let workspaceURL else { return }
        consentStore.revokeConsent(for: workspaceURL)
        cancelAuthorizedAgents()
    }

    private func cancelAuthorizedAgents() {
        agentAuthorizationGeneration += 1
        contextLifecycleGeneration += 1
        contextPending = false
        if postCallStatus == "context_pending" {
            postCallContextTarget = nil
            postCallStatus = "needs_setup"
            postCallMessage = "Context agents were disabled before the final transcript was covered. Enable them and retry review; temporary audio is retained."
            recordSessionMutation(immediate: true)
        }
        contextDebounceTask?.cancel()
        contextDebounceTask = nil
        contextTask?.cancel()
        contextTask = nil
        activeContextRunID = nil
        mediumActivity = contextFinding.map { .completed($0.title) } ?? .idle
        hasAgentConsent = false
        codexModels = []
        codexSkills = []
        codexMessage = "Context agents are disabled."
        deepTask?.cancel()
        deepTask = nil
        let activeInvestigationIDs = self.activeInvestigationIDs
        self.activeInvestigationIDs.removeAll()
        for id in activeInvestigationIDs {
            investigationTasks[id]?.cancel()
            investigationTasks[id] = nil
            if let index = investigations.firstIndex(where: { $0.id == id }) {
                investigations[index].activity = .failed("Context agents were disabled")
            }
        }
        if !activeInvestigationIDs.isEmpty { recordSessionMutation(immediate: true) }
        Task { [weak self] in
            await self?.agentCoordinator?.cancel(.medium)
            for id in activeInvestigationIDs { await self?.agentCoordinator?.cancelInvestigation(id: id) }
        }
    }

    public func refreshCodex() async {
        guard let agentCoordinator else { return }
        guard !requiresOpenAIKeyForAgents || hasTranscriptionCredential else {
            codexMessage = "Add an OpenAI API key in Settings to load model IDs."
            return
        }
        codexRefreshGeneration += 1
        let generation = codexRefreshGeneration
        let authorization = agentAuthorizationGeneration
        let workspace = workspaceURL ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let workspaceIdentity = workspaceURL?.standardizedFileURL.resolvingSymlinksInPath().path
        isLoadingCodex = true
        codexMessage = "Loading OpenAI models…"
        do {
            let (models, inventory) = try await agentCoordinator.discover(in: workspace)
            guard generation == codexRefreshGeneration,
                authorization == agentAuthorizationGeneration,
                self.workspaceURL?.standardizedFileURL.resolvingSymlinksInPath().path == workspaceIdentity
            else {
                return
            }
            codexModels = models
            codexSkills = inventory.skills.filter(\.enabled)
            if batchTranscriptionModel.isEmpty, codexModels.contains(where: { $0.model == "gpt-transcribe" }) {
                setBatchTranscriptionModel("gpt-transcribe")
            }
            codexMessage = codexModels.isEmpty
                ? "No models were returned for this API key. You can still enter a model ID manually."
                : "\(codexModels.count) model IDs available. Select a model for each agent."
        } catch {
            guard generation == codexRefreshGeneration,
                authorization == agentAuthorizationGeneration,
                self.workspaceURL?.standardizedFileURL.resolvingSymlinksInPath().path == workspaceIdentity
            else {
                return
            }
            codexMessage = error.localizedDescription
        }
        if generation == codexRefreshGeneration { isLoadingCodex = false }
        if generation == codexRefreshGeneration, canUseWorkspaceAgents, contextPending, phase == .listening {
            scheduleContextUpdate(after: .zero)
        }
    }

    public var recentModelIDs: [String] { modelSelectionStore.recentModels }

    public func modelAvailability(_ modelID: String, for agent: String = "agent") -> String {
        guard !modelID.isEmpty else { return "Choose a model ID for the \(agent)." }
        if codexModels.contains(where: { $0.model == modelID }) { return "Available in the current API model list." }
        if !codexModels.isEmpty { return "Not listed by the current API key. This ID can still be tried when requested." }
        return "Not verified yet. Refresh the list when convenient; this ID can still be tried when requested."
    }

    private func invalidateAgentCredential() {
        codexRefreshGeneration += 1
        agentAuthorizationGeneration += 1
        isLoadingCodex = false
        codexModels = []
        codexSkills = []
        let investigationsToCancel = activeInvestigationIDs
        contextLifecycleGeneration += 1
        contextPending = false
        contextDebounceTask?.cancel(); contextDebounceTask = nil
        contextTask?.cancel(); contextTask = nil
        activeContextRunID = nil
        mediumActivity = .idle
        contextMessage = "OpenAI API key changed. Your model choices have been kept; refresh the list to check availability."
        for id in investigationsToCancel {
            investigationTasks[id]?.cancel()
            investigationTasks[id] = nil
            if let index = investigations.firstIndex(where: { $0.id == id }) {
                investigations[index].activity = .failed("OpenAI API key changed")
            }
        }
        activeInvestigationIDs.removeAll()
        if !investigationsToCancel.isEmpty { recordSessionMutation(immediate: true) }
        codexMessage = hasTranscriptionCredential
            ? "OpenAI API key changed. Refresh the model list. Manually entered IDs remain available."
            : "Add an OpenAI API key before requesting workspace agents."
        Task { [weak self] in
            await self?.agentCoordinator?.cancel(.medium)
            for id in investigationsToCancel { await self?.agentCoordinator?.cancelInvestigation(id: id) }
        }
    }

    public func refreshContext() {
        guard !isDemo else {
            contextMessage = "Demo uses sample context; start a new conversation for live workspace agents."
            return
        }
        guard transcriptEntries.contains(where: { $0.isFinal && !$0.text.isEmpty }) else {
            contextMessage = "A completed utterance is needed before Context can refresh."
            return
        }
        contextPending = true
        contextManualRefresh = true
        scheduleContextUpdate(after: .zero, allowIdle: true)
    }

    public func investigate(selection: TranscriptSelection, question: String) {
        guard !isDemo else {
            contextMessage = "Demo uses sample context; start a new conversation for live workspace agents."
            return
        }
        let quote = selection.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty, quote.count <= 12_000, prompt.count <= 2_000 else {
            contextMessage = "Select up to 12,000 characters and keep the question under 2,000 characters."
            return
        }
        guard canUseWorkspaceAgents else { contextMessage = "Enable Context agents and configure an OpenAI key to investigate this passage."; return }
        guard activeInvestigationIDs.isEmpty else { contextMessage = "An investigation is already running."; return }
        guard let agentCoordinator, !deepModel.isEmpty else {
            contextMessage = "Choose an investigation model before starting."
            return
        }
        let id = UUID()
        let item = PassageInvestigation(id: id, selection: selection, question: prompt, activity: .working, finding: nil)
        investigations.insert(item, at: 0)
        activeInvestigationIDs.insert(id)
        investigationProvenance[id] = InvestigationProvenance(model: deepModel, createdAt: Date())
        recordSessionMutation(immediate: true)
        let conversation = conversationGeneration
        let authorization = agentAuthorizationGeneration
        ensureActiveSession()
        guard let sessionID = activeSessionID else { return }
        let originalIDs = Set(postCallTranscriptEntries.map(\.id))
        let currentIDs = Set(transcriptEntries.map(\.id))
        let selectedOriginal = !selection.entryIDs.isEmpty
            && selection.entryIDs.allSatisfy(originalIDs.contains)
            && !selection.entryIDs.allSatisfy(currentIDs.contains)
        let selectedEntries = selectedOriginal ? postCallTranscriptEntries : transcriptEntries
        let snapshot = CallContextSnapshot(sessionID: sessionID, revision: transcriptRevision, entries: selectedEntries,
                                           workspace: hasAgentConsent ? workspaceURL : nil, reasoningEffort: investigationEffort)
        let selectedContext = contextFinding
        let selectedModel = deepModel
        investigationTasks[id] = Task { [weak self] in
            do {
                let finding = try await agentCoordinator.investigate(
                    selection: selection, question: prompt, snapshot: snapshot,
                    context: selectedContext, model: selectedModel, id: id
                )
                guard let self, self.conversationGeneration == conversation,
                      self.agentAuthorizationGeneration == authorization, self.canUseWorkspaceAgents,
                      !Task.isCancelled, self.activeInvestigationIDs.contains(id),
                      let index = self.investigations.firstIndex(where: { $0.id == id }) else { return }
                self.investigations[index].finding = finding
                self.investigations[index].activity = .completed(finding.title)
                self.activeInvestigationIDs.remove(id)
                self.investigationTasks[id] = nil
                self.recordSessionMutation(immediate: true)
            } catch {
                guard let self, self.conversationGeneration == conversation,
                      self.agentAuthorizationGeneration == authorization,
                      !Task.isCancelled,
                      self.activeInvestigationIDs.contains(id),
                      let index = self.investigations.firstIndex(where: { $0.id == id }) else { return }
                self.investigations[index].activity = .failed(error.localizedDescription)
                self.activeInvestigationIDs.remove(id)
                self.investigationTasks[id] = nil
                self.recordSessionMutation(immediate: true)
            }
        }
    }

    public func cancelInvestigation(id: UUID) {
        guard activeInvestigationIDs.remove(id) != nil else { return }
        investigationTasks[id]?.cancel()
        investigationTasks[id] = nil
        if let index = investigations.firstIndex(where: { $0.id == id }) { investigations[index].activity = .failed("Cancelled") }
        recordSessionMutation(immediate: true)
        Task { await agentCoordinator?.cancelInvestigation(id: id) }
    }

    func runDeepInvestigation() {
        guard let entry = transcriptEntries.last(where: \.isFinal) else { return }
        investigate(selection: TranscriptSelection(text: entry.text, entryIDs: [entry.id]), question: "Find the most relevant supporting context.")
    }

    func cancelDeepInvestigation() {
        for id in activeInvestigationIDs { cancelInvestigation(id: id) }
    }

    private func handle(_ event: TranscriptionEvent, generation: Int) async {
        guard sessionGeneration == generation else { return }
        switch event {
        case .committed(let itemID, let previous):
            let id = entryID(itemID)
            liveCaptureEntryIDs.insert(id)
            if activeRecordingSessionID != nil { postCallLiveEntryIDs.insert(id) }
            if let previous { committedPredecessors[id] = entryID(previous) }
            else if !committedRoots.contains(id) { committedRoots.append(id) }
            if !transcriptEntries.contains(where: { $0.id == id }) { _ = upsertEntry(id: id, text: "", final: false) }
            else { reorderEntries() }
            recordSessionMutation(immediate: false)
        case .partial(let itemID, let delta):
            let id = entryID(itemID)
            liveCaptureEntryIDs.insert(id)
            if activeRecordingSessionID != nil { postCallLiveEntryIDs.insert(id) }
            guard transcriptEntries.first(where: { $0.id == id })?.isFinal != true else { return }
            activePartialItemID = itemID
            partialTexts[id, default: ""] += delta
            partialTranscript = partialTexts[id] ?? ""
            _ = upsertEntry(id: id, text: partialTranscript, final: false)
            transcript = partialTranscript
            recordSessionMutation(immediate: false)
        case .completed(let itemID, let text):
            let id = entryID(itemID)
            liveCaptureEntryIDs.insert(id)
            if activeRecordingSessionID != nil { postCallLiveEntryIDs.insert(id) }
            let changed = upsertEntry(id: id, text: text, final: true)
            if activePartialItemID == itemID { activePartialItemID = nil; partialTranscript = ""; transcript = text }
            partialTexts[id] = nil
            if changed {
                transcriptRevision += 1
                contextPending = true
                recordSessionMutation(immediate: true)
                if !text.isEmpty { scheduleContextUpdate(after: .seconds(contextDebounceSeconds)) }
            }
        case .recovering(let attempt, let maximum):
            transcriptionConnectionStatus = "Reconnecting transcription (\(attempt)/\(maximum))"
            if activeGapID == nil {
                let id = "system:gap:\(UUID())"
                activeGapID = id
                for index in transcriptEntries.indices where !transcriptEntries[index].isFinal {
                    transcriptEntries[index].wasInterrupted = true
                }
                captureSessionID = UUID()
                committedPredecessors = [:]; committedRoots = []
                transcriptEntries.append(TranscriptEntry(id: id, timestamp: Date(), text: "[System notice] Transcription connection interrupted. Audio around this time may be missing, including unfinished speech. Reconnecting…", isFinal: true))
                activePartialItemID = nil; partialTexts = [:]; partialTranscript = ""
                recordSessionMutation(immediate: true)
            }
        case .recovered:
            finishTranscriptionGap("Transcription resumed at \(Date().formatted(date: .omitted, time: .standard)). Audio during the interruption was not replayed.")
            transcriptionConnectionStatus = nil
        case .transportLost:
            await failLiveSession("Transcription connection was lost. Resume to reconnect.", generation: generation)
        case .failed(let message): await failLiveSession(message, generation: generation)
        }
    }

    private func finishTranscriptionGap(_ ending: String) {
        if let id = activeGapID, let index = transcriptEntries.firstIndex(where: { $0.id == id }) {
            transcriptEntries[index].text = "[System notice] Transcription connection interrupted. Audio around this time may be missing, including unfinished speech. " + ending
            recordSessionMutation(immediate: true)
        }
        activeGapID = nil
        transcriptionConnectionStatus = nil
    }

    private func entryID(_ providerID: String) -> String { "\(captureSessionID.uuidString):\(providerID)" }

    @discardableResult
    private func upsertEntry(id: String, text: String, final: Bool) -> Bool {
        var changed = false
        if let index = transcriptEntries.firstIndex(where: { $0.id == id }) {
            changed = transcriptEntries[index].text != text || (!transcriptEntries[index].isFinal && final)
            guard changed else { return false }
            transcriptEntries[index].text = text
            transcriptEntries[index].isFinal = transcriptEntries[index].isFinal || final
        } else {
            transcriptEntries.append(TranscriptEntry(id: id, timestamp: Date(), text: text, isFinal: final))
            changed = true
        }
        reorderEntries()
        return changed
    }

    private func reorderEntries() {
        guard !committedPredecessors.isEmpty else { return }
        let currentPrefix = "\(captureSessionID.uuidString):"
        let currentEntries = transcriptEntries.filter { $0.id.hasPrefix(currentPrefix) }
        let byID = Dictionary(uniqueKeysWithValues: currentEntries.map { ($0.id, $0) })
        var ordered = transcriptEntries.filter { !$0.id.hasPrefix(currentPrefix) }
        var visited = Set<String>()
        func appendChain(from start: String) {
            var cursor: String? = start
            while let id = cursor, !visited.contains(id), let entry = byID[id] {
                visited.insert(id); ordered.append(entry)
                cursor = currentEntries.first(where: { committedPredecessors[$0.id] == id })?.id
            }
        }
        for root in committedRoots { appendChain(from: root) }
        for entry in currentEntries where !visited.contains(entry.id) { appendChain(from: entry.id) }
        transcriptEntries = ordered
    }

    private func ingestDemo(_ text: String, generation: Int) {
        guard sessionGeneration == generation else { return }
        let id = "demo:\(transcriptEntries.count)"
        transcript = text
        _ = upsertEntry(id: id, text: text, final: true)
        transcriptRevision += 1
        contextTranscriptRevision = transcriptRevision
        cues = []
        let sampleTranscript = transcriptEntries.filter { $0.id.hasPrefix("demo:") && $0.isFinal }
            .map(\.text).joined(separator: " ")
        let finding = AgentFinding(
            id: "demo-context",
            title: "Simulated context",
            summary: "Sample transcript only: \(sampleTranscript)",
            evidence: [],
            confidence: 1,
            skillsUsed: [],
            tier: .medium
        )
        contextFinding = finding
        contextUpdatedAt = Date()
        contextTranscriptRevision = transcriptRevision
        contextFindingModel = "Sample"
        mediumActivity = .completed("Simulated context")
        contextMessage = "Sample context only. No workspace files or agents were used."
        recordSessionMutation(immediate: true)
    }

    private func failLiveSession(_ message: String, generation: Int) async {
        guard sessionGeneration == generation else { return }
        sessionGeneration += 1
        let cleanupGeneration = sessionGeneration
        phase = .idle
        isStopping = true
        let runningInvestigations = Set(activeInvestigationIDs)
        activeInvestigationIDs.removeAll()
        for id in runningInvestigations {
            investigationTasks[id]?.cancel()
            investigationTasks[id] = nil
            if let index = investigations.firstIndex(where: { $0.id == id }) {
                investigations[index].activity = .failed("Session stopped after an error")
            }
        }
        if !runningInvestigations.isEmpty { recordSessionMutation(immediate: true) }
        mediumActivity = .idle
        demoTask?.cancel(); demoTask = nil
        contextLifecycleGeneration += 1
        contextDebounceTask?.cancel(); contextDebounceTask = nil
        contextTask?.cancel(); contextTask = nil
        activeContextRunID = nil
        contextPending = true
        audioDelivery?.cancel()
        finishTranscriptionEvents()
        await capture.stop()
        await finishTemporaryRecording()
        await finishAudioSending()
        await realtime.disconnect()
        await agentCoordinator?.cancel(.medium)
        for id in runningInvestigations { await agentCoordinator?.cancelInvestigation(id: id) }
        guard sessionGeneration == cleanupGeneration else { return }
        phase = .failed(message)
        isStopping = false
    }

    private func finishStopping(generation: Int, activeInvestigationIDs: Set<UUID>) async {
        audioDelivery?.cancel()
        finishTranscriptionEvents()
        await capture.stop()
        await finishAudioSending()
        await realtime.disconnect()
        await finishTemporaryRecording()
        await agentCoordinator?.cancel(.medium)
        for id in activeInvestigationIDs { await agentCoordinator?.cancelInvestigation(id: id) }
        guard sessionGeneration == generation else { return }
        isStopping = false
        stopTask = nil
        if postCallStatus == "pending", !batchTranscriptionModel.isEmpty, canRunAgents {
            retryPostCallReview()
        }
    }

    private func finishTemporaryRecording() async {
        guard let recordingID = activeRecordingSessionID else { return }
        activeRecordingSessionID = nil
        guard let recordingStore else { return }
        do {
            try await recordingStore.finish(sessionID: recordingID)
            let manifest = try await recordingStore.manifest(sessionID: recordingID)
            recordingStatus = "Temporary recording saved · expires in 24 hours"
            postCallStatus = "pending"
            postCallAudioExpiresAt = manifest.expiresAt
            postCallMessage = nil
            recordSessionMutation(immediate: true)
            _ = await flushPersistence()
            if batchTranscriptionModel.isEmpty || !canRunAgents {
                postCallMessage = "Choose a post-call transcription model and Context model to review this recording."
            }
        } catch {
            recordingStatus = "Recording could not be finalized: \(error.localizedDescription)"
            postCallStatus = "failed"
            postCallMessage = error.localizedDescription
            recordSessionMutation(immediate: true)
        }
    }

    private func beginCaptureSession() {
        sessionGeneration += 1
        captureSessionID = UUID()
        liveCaptureEntryIDs = []
        ensureActiveSession()
        demoTask?.cancel(); demoTask = nil
        partialTranscript = ""
        partialTexts = [:]
        activePartialItemID = nil
        committedPredecessors = [:]; committedRoots = []
        finishTranscriptionEvents()
    }

    private func scheduleContextUpdate(after delay: Duration, allowIdle: Bool = false) {
        guard contextPending, !isDemo, canRunAgents, (phase == .listening || allowIdle || contextManualRefresh), contextDebounceTask == nil else { return }
        let lifecycle = contextLifecycleGeneration
        contextDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, self.contextLifecycleGeneration == lifecycle else { return }
            self.contextDebounceTask = nil
            await self.runContextUpdate(lifecycle: lifecycle)
        }
    }

    private func runContextUpdate(lifecycle: Int) async {
        guard contextPending, contextTask == nil, canRunAgents, !isDemo,
              transcriptEntries.contains(where: { $0.isFinal && !$0.text.isEmpty }),
              let agentCoordinator, !contextModel.isEmpty else { return }
        if let lastContextStartedAt, Date().timeIntervalSince(lastContextStartedAt) < contextMinimumIntervalSeconds {
            let wait = contextMinimumIntervalSeconds - Date().timeIntervalSince(lastContextStartedAt)
            scheduleContextUpdate(after: .seconds(wait)); return
        }
        contextPending = false
        let runID = UUID(); activeContextRunID = runID
        let conversation = conversationGeneration
        let authorization = agentAuthorizationGeneration
        let coveredTranscriptRevision = transcriptRevision
        ensureActiveSession()
        guard let sessionID = activeSessionID else { return }
        let isFinalReview = postCallContextTarget.map {
            $0.sessionID == sessionID && $0.transcriptRevision == transcriptRevision && $0.sessionGeneration == sessionGeneration
        } ?? false
        let snapshot = CallContextSnapshot(sessionID: sessionID, revision: transcriptRevision, entries: transcriptEntries,
                                           workspace: hasAgentConsent ? workspaceURL : nil, isFinalReview: isFinalReview, contextGuidance: contextGuidance, contextLimits: contextLimits, reasoningEffort: contextEffort)
        let previous = contextFinding
        let model = contextModel
        lastContextStartedAt = Date()
        mediumActivity = .working
        contextTask = Task { [weak self] in
            do {
                let finding = try await agentCoordinator.updateContext(snapshot: snapshot, previous: previous, model: model)
                guard let self, self.contextLifecycleGeneration == lifecycle, self.conversationGeneration == conversation,
                      self.agentAuthorizationGeneration == authorization, self.canUseWorkspaceAgents, !Task.isCancelled,
                      self.activeContextRunID == runID else { return }
                self.contextFinding = finding; self.contextUpdatedAt = Date(); self.contextMessage = nil
                self.contextTranscriptRevision = coveredTranscriptRevision
                self.contextFindingModel = model
                self.agentFindings.removeAll { $0.tier == .medium }; self.agentFindings.insert(finding, at: 0)
                self.mediumActivity = .completed(finding.title)
                self.recordSessionMutation(immediate: true)
                if let target = self.postCallContextTarget,
                   target.sessionID == sessionID, target.transcriptRevision == coveredTranscriptRevision,
                   target.sessionGeneration == self.sessionGeneration {
                    self.postCallContextTarget = nil
                    let recordingIDs = self.postCallRecordingIDs
                    Task { await self.finishPostCallIfContextSaved(sessionID: sessionID, sessionGeneration: target.sessionGeneration, recordingIDs: recordingIDs, expectedRevision: coveredTranscriptRevision) }
                }
            } catch {
                guard let self, self.contextLifecycleGeneration == lifecycle, self.conversationGeneration == conversation,
                      self.agentAuthorizationGeneration == authorization, !Task.isCancelled,
                      self.activeContextRunID == runID else { return }
                self.contextMessage = error.localizedDescription
                self.mediumActivity = .failed(error.localizedDescription)
                if let target = self.postCallContextTarget,
                   target.sessionID == sessionID, target.transcriptRevision == coveredTranscriptRevision,
                   target.sessionGeneration == self.sessionGeneration {
                    self.postCallContextTarget = nil
                    self.postCallStatus = "failed"
                    self.postCallMessage = "Context could not be generated from the final transcript: \(error.localizedDescription). Temporary audio is retained."
                    self.recordSessionMutation(immediate: true)
                }
            }
            guard let self, self.activeContextRunID == runID else { return }
            self.activeContextRunID = nil; self.contextTask = nil
            self.contextManualRefresh = false
            if self.contextPending { self.scheduleContextUpdate(after: .seconds(self.contextDebounceSeconds)) }
        }
    }

    private func finishAudioSending() async {
        guard let delivery = audioDelivery else { return }
        await delivery.stop()
        if audioDelivery === delivery { audioDelivery = nil }
    }

    private func finishTranscriptionEvents() {
        finishTranscriptionGap("Listening stopped before the connection recovered.")
        transcriptionContinuation?.finish()
        transcriptionContinuation = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
    }
}
