import Foundation
import XCTest
@testable import MurmurApp

@MainActor
final class AppModelPersistenceTests: XCTestCase {
    func testFinalizedSpeechAutosavesWhileListeningAndReopensPausedWithoutAgentCalls() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanUp() }
        let store = InMemorySessionStore()
        let capture = PersistenceCaptureFake()
        let agents = PersistenceAgentFake()
        let realtime = PersistenceRealtimeFake()
        let model = harness.makeModel(store: store, capture: capture, realtime: realtime, agents: agents)
        await model.loadWorkspace(from: harness.workspace)
        await start(model, realtime: realtime)
        await realtime.emit(.completed(itemID: "final", text: "The launch date is Friday."))
        try await waitUntil { model.transcriptEntries.last?.text == "The launch date is Friday." }

        let sessionID = try XCTUnwrap(model.activeSessionID)
        let saved = try await waitForRecord(sessionID, in: store) { $0.transcript.last?.text == "The launch date is Friday." }
        XCTAssertEqual(saved?.transcript.count, 1)
        XCTAssertEqual(model.phase, .listening, "Autosave should finish without requiring Stop.")

        let reopenedCapture = PersistenceCaptureFake()
        let reopenedRealtime = PersistenceRealtimeFake()
        let reopenedAgents = PersistenceAgentFake()
        let reopened = harness.makeModel(store: store, capture: reopenedCapture, realtime: reopenedRealtime, agents: reopenedAgents)
        let didOpen = await reopened.openSession(id: sessionID)
        XCTAssertTrue(didOpen)
        XCTAssertEqual(reopened.phase, .idle)
        XCTAssertEqual(reopened.transcriptEntries.map(\.text), ["The launch date is Friday."])
        XCTAssertEqual(reopenedCapture.startCount, 0)
        let reopenedConnectCount = await reopenedRealtime.connectCount
        let reopenedDiscoverCount = await reopenedAgents.discoverCount
        let reopenedContextCount = await reopenedAgents.contextCallCount
        XCTAssertEqual(reopenedConnectCount, 0)
        XCTAssertEqual(reopenedDiscoverCount, 0)
        XCTAssertEqual(reopenedContextCount, 0)
        await model.stop()
    }

    func testPartialTranscriptCheckpointPersistsWithinOneSecond() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanUp() }
        let store = InMemorySessionStore()
        let realtime = PersistenceRealtimeFake()
        let model = harness.makeModel(store: store, realtime: realtime)
        await model.loadWorkspace(from: harness.workspace)
        await start(model, realtime: realtime)
        await realtime.emit(.partial(itemID: "partial", delta: "unfinished phrase"))
        try await waitUntil { model.transcript == "unfinished phrase" }
        let sessionID = try XCTUnwrap(model.activeSessionID)

        let saved = try await waitForRecord(sessionID, in: store, timeout: .seconds(1)) {
            $0.transcript.contains { $0.text == "unfinished phrase" && !$0.isFinal }
        }
        XCTAssertNotNil(saved)
        await model.stop()
    }

    func testNewConversationPreservesPriorHistoryAndIdleSettingsDoNotCreateHistory() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanUp() }
        let store = InMemorySessionStore()
        let realtime = PersistenceRealtimeFake()
        let model = harness.makeModel(store: store, realtime: realtime)
        model.transcriptionModel = .accurate
        await model.loadSessionHistory()
        XCTAssertTrue(model.sessionHistory.isEmpty)

        await model.loadWorkspace(from: harness.workspace)
        await start(model, realtime: realtime)
        await realtime.emit(.completed(itemID: "first", text: "First saved conversation."))
        let firstID = try XCTUnwrap(model.activeSessionID)
        _ = try await waitForRecord(firstID, in: store) { $0.transcript.last?.text == "First saved conversation." }

        await model.newConversation()
        XCTAssertNil(model.activeSessionID)
        let firstRecord = try await store.load(id: firstID).session
        XCTAssertEqual(firstRecord.transcript.last?.text, "First saved conversation.")
        XCTAssertTrue(model.transcriptEntries.isEmpty)
    }

    func testBlankCommittedEntryAndSettingsChangeDoNotCreateHistoryOnStopOrQuit() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanUp() }
        let store = InMemorySessionStore()
        let realtime = PersistenceRealtimeFake()
        let model = harness.makeModel(store: store, realtime: realtime)
        await model.loadWorkspace(from: harness.workspace)
        await start(model, realtime: realtime)
        await realtime.emit(.committed(itemID: "empty", previousItemID: nil))
        try await waitUntil { model.transcriptEntries.contains(where: { !$0.isFinal && $0.text.isEmpty }) }

        model.transcriptionModel = .accurate
        await model.stop()
        let canQuit = await model.prepareForQuit()
        let history = try await store.list()
        XCTAssertTrue(canQuit)
        XCTAssertTrue(history.isEmpty)
    }

    func testFailedSaveBlocksNewOpenAndQuitWithoutDiscardingCurrentTranscript() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanUp() }
        let store = FailureSessionStore()
        let target = SavedSession(id: UUID(), title: "Other conversation", transcript: [
            SavedTranscriptEntry(id: "other", timestamp: Date(), text: "Keep me", isFinal: true)
        ])
        await store.insert(target)
        let realtime = PersistenceRealtimeFake()
        let model = harness.makeModel(store: store, realtime: realtime)
        await model.loadWorkspace(from: harness.workspace)
        await start(model, realtime: realtime)
        await store.failSaves(true)
        await realtime.emit(.completed(itemID: "current", text: "Unsaved current conversation."))
        try await waitUntil { model.transcriptEntries.last?.text == "Unsaved current conversation." }
        try await waitUntil { model.persistenceStatus == "Save failed" }
        let originalID = try XCTUnwrap(model.activeSessionID)

        await model.newConversation()
        XCTAssertEqual(model.activeSessionID, originalID)
        XCTAssertEqual(model.transcriptEntries.last?.text, "Unsaved current conversation.")
        let didOpenOther = await model.openSession(id: target.id)
        XCTAssertFalse(didOpenOther)
        XCTAssertEqual(model.transcriptEntries.last?.text, "Unsaved current conversation.")
        let canQuit = await model.prepareForQuit()
        XCTAssertFalse(canQuit)
        XCTAssertEqual(model.transcriptEntries.last?.text, "Unsaved current conversation.")
        await model.stop()
    }

    func testMissingWorkspaceReopensReadablePausedAndDoesNotDiscoverOrCapture() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanUp() }
        let store = InMemorySessionStore()
        let session = SavedSession(
            id: UUID(), title: "Offline call", workspacePath: harness.root.appendingPathComponent("gone").path,
            workspaceName: "Missing workspace", transcript: [
                SavedTranscriptEntry(id: "old:phrase", timestamp: Date(), text: "Retained evidence", isFinal: true)
            ]
        )
        try await store.save(session)
        let capture = PersistenceCaptureFake()
        let realtime = PersistenceRealtimeFake()
        let agents = PersistenceAgentFake()
        let model = harness.makeModel(store: store, capture: capture, realtime: realtime, agents: agents)

        let didOpen = await model.openSession(id: session.id)
        XCTAssertTrue(didOpen)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.transcriptEntries.map(\.text), ["Retained evidence"])
        XCTAssertTrue(model.canRelinkWorkspace)
        XCTAssertEqual(capture.startCount, 0)
        let connectCount = await realtime.connectCount
        let discoverCount = await agents.discoverCount
        let contextCallCount = await agents.contextCallCount
        XCTAssertEqual(connectCount, 0)
        XCTAssertEqual(discoverCount, 0)
        XCTAssertEqual(contextCallCount, 0)
    }

    func testResumingWithRepeatedProviderItemIDAppendsToStoredEntry() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanUp() }
        let store = InMemorySessionStore()
        let realtime = PersistenceRealtimeFake()
        let model = harness.makeModel(store: store, realtime: realtime)
        await model.loadWorkspace(from: harness.workspace)
        await start(model, realtime: realtime)
        await realtime.emit(.completed(itemID: "repeat", text: "Before pause"))
        try await waitUntil { model.transcriptEntries.filter(\.isFinal).count == 1 }
        await model.stop()
        await start(model, realtime: realtime)
        await realtime.emit(.completed(itemID: "repeat", text: "After resume"))
        try await waitUntil { model.transcriptEntries.filter(\.isFinal).count == 2 }
        XCTAssertEqual(model.transcriptEntries.map(\.text), ["Before pause", "After resume"])
        await model.stop()
    }

    func testContextFindingRetainsCoveredTranscriptRevisionWhenNewFinalArrives() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanUp() }
        let store = InMemorySessionStore()
        let realtime = PersistenceRealtimeFake()
        let agents = PersistenceAgentFake(holdContext: true)
        let model = harness.makeModel(store: store, realtime: realtime, agents: agents,
                                     contextDebounceSeconds: 0, contextMinimumIntervalSeconds: 0)
        await model.loadWorkspace(from: harness.workspace)
        model.contextModel = "context-model"
        model.deepModel = "deep-model"
        model.grantAgentConsent()
        try await waitUntil { !model.deepModel.isEmpty }
        await start(model, realtime: realtime)
        await realtime.emit(.completed(itemID: "one", text: "First utterance"))
        try await waitUntil { await agents.contextCallCount == 1 }
        await realtime.emit(.completed(itemID: "two", text: "Newer utterance"))
        try await waitUntil { model.transcriptEntries.filter(\.isFinal).count == 2 }
        let sessionID = try XCTUnwrap(model.activeSessionID)
        await agents.completeContext(0, title: "First context")
        let saved = try await waitForRecord(sessionID, in: store) {
            $0.context?.title == "First context" && $0.transcriptRevision == 2 && $0.contextTranscriptRevision == 1
        }
        XCTAssertNotNil(saved)
        try await waitUntil { await agents.contextCallCount == 2 }
        await agents.completeContext(1, title: "Latest context")
        await model.stop()
    }

    func testDeleteWhileInvestigationIsPendingCannotResurrectSession() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanUp() }
        let store = InMemorySessionStore()
        let realtime = PersistenceRealtimeFake()
        let agents = PersistenceAgentFake(holdInvestigations: true)
        let model = harness.makeModel(store: store, realtime: realtime, agents: agents)
        await model.loadWorkspace(from: harness.workspace)
        model.contextModel = "context-model"
        model.deepModel = "deep-model"
        model.grantAgentConsent()
        try await waitUntil { !model.deepModel.isEmpty }
        await start(model, realtime: realtime)
        await realtime.emit(.completed(itemID: "phrase", text: "Investigate this evidence."))
        try await waitUntil { model.transcriptEntries.contains(where: \.isFinal) }
        let sessionID = try XCTUnwrap(model.activeSessionID)
        let selection = TranscriptSelection(text: "Investigate this evidence.", entryIDs: [try XCTUnwrap(model.transcriptEntries.first?.id)])
        model.investigate(selection: selection, question: "What supports this?")
        try await waitUntil { model.isInvestigating }
        try await waitUntil { await agents.investigationCallCount == 1 }

        let didDelete = await model.deleteSession(id: sessionID)
        XCTAssertTrue(didDelete)
        await agents.completeInvestigation(title: "Late result")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(model.transcriptEntries.isEmpty)
        XCTAssertTrue(model.investigations.isEmpty)
        let remaining = try await store.list()
        XCTAssertFalse(remaining.contains(where: { $0.id == sessionID }))
    }

    func testInvestigationModelAndCreationTimeSurviveModelSelectionChanges() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanUp() }
        let store = InMemorySessionStore()
        let realtime = PersistenceRealtimeFake()
        let agents = PersistenceAgentFake()
        let model = harness.makeModel(store: store, realtime: realtime, agents: agents)
        await model.loadWorkspace(from: harness.workspace)
        model.contextModel = "context-model"
        model.deepModel = "deep-model"
        model.grantAgentConsent()
        try await waitUntil { !model.deepModel.isEmpty }
        await start(model, realtime: realtime)
        await realtime.emit(.completed(itemID: "evidence", text: "A traceable claim."))
        try await waitUntil { model.transcriptEntries.contains(where: \.isFinal) }
        let sessionID = try XCTUnwrap(model.activeSessionID)
        let originalModel = model.deepModel
        let selection = TranscriptSelection(text: "A traceable claim.", entryIDs: [try XCTUnwrap(model.transcriptEntries.first?.id)])
        model.investigate(selection: selection, question: "Find evidence.")
        try await waitUntil {
            guard let activity = model.investigations.first?.activity else { return false }
            if case .completed = activity { return true }
            return false
        }
        let first = try await waitForRecord(sessionID, in: store) { $0.investigations.first?.model == originalModel }
        let createdAt = try XCTUnwrap(first?.investigations.first?.createdAt)

        model.deepModel = "a-different-model"
        let updated = try await waitForRecord(sessionID, in: store) {
            $0.investigationModel == "a-different-model" && $0.investigations.first?.model == originalModel && $0.investigations.first?.createdAt == createdAt
        }
        XCTAssertEqual(updated?.investigations.first?.model, originalModel)
        XCTAssertEqual(updated?.investigations.first?.createdAt, createdAt)
        await model.stop()
    }

    func testRetryAfterCommittedSaveErrorAdvancesRevisionAndClearsFailure() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanUp() }
        let store = FailureSessionStore()
        await store.commitThenFailNextSave()
        let realtime = PersistenceRealtimeFake()
        let model = harness.makeModel(store: store, realtime: realtime)
        await model.loadWorkspace(from: harness.workspace)
        await start(model, realtime: realtime)
        await realtime.emit(.completed(itemID: "retry", text: "Committed before failure."))
        try await waitUntil { model.transcriptEntries.last?.text == "Committed before failure." && model.persistenceStatus == "Save failed" }
        let sessionID = try XCTUnwrap(model.activeSessionID)
        let committedRevision = try await store.load(id: sessionID).session.revision

        await model.retrySave()
        try await waitUntil { model.isPersistenceClean && model.persistenceStatus == "Saved" }
        let retried = try await store.load(id: sessionID).session
        XCTAssertGreaterThan(retried.revision, committedRevision)
        XCTAssertEqual(retried.transcript.last?.text, "Committed before failure.")
        await model.stop()
    }
}

@MainActor
private final class PersistenceHarness {
    let defaults: UserDefaults
    let root: URL
    let workspace: URL
    private let suite: String

    init() throws {
        suite = "AppModelPersistenceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try "# Workspace".write(to: workspace.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    }

    func makeModel(
        store: any SessionStoring,
        capture: PersistenceCaptureFake = PersistenceCaptureFake(),
        realtime: PersistenceRealtimeFake = PersistenceRealtimeFake(),
        agents: PersistenceAgentFake = PersistenceAgentFake(),
        contextDebounceSeconds: Double = 60,
        contextMinimumIntervalSeconds: Double = 60
    ) -> AppModel {
        AppModel(codexRuntime: PersistenceCodexFake(), userDefaults: defaults,
                 launchAPIKey: "test-key", capture: capture, realtime: realtime,
                 sessionStore: store, conversationAgents: agents,
                 contextDebounceSeconds: contextDebounceSeconds,
                 contextMinimumIntervalSeconds: contextMinimumIntervalSeconds)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private func start(_ model: AppModel, realtime: PersistenceRealtimeFake) async {
    await model.startLive()
    for _ in 0..<100 where model.phase != .listening {
        try? await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(model.phase, .listening)
    _ = realtime
}

@MainActor
private func waitUntil(
    iterations: Int = 400,
    condition: @MainActor () async -> Bool
) async throws {
    for _ in 0..<iterations {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Condition did not become true")
}

private func waitForRecord(
    _ id: UUID,
    in store: any SessionStoring,
    timeout: Duration = .seconds(5),
    matching predicate: @Sendable (SavedSession) -> Bool
) async throws -> SavedSession? {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if let record = try? await store.load(id: id).session, predicate(record) { return record }
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Expected saved session did not appear")
    return nil
}

@MainActor
private final class PersistenceCaptureFake: AudioCaptureManaging {
    private(set) var startCount = 0
    func start(mode: AudioSourceMode, audioHandler: @escaping @Sendable (Data) -> Void,
               errorHandler: (@Sendable (String) -> Void)?) async throws { startCount += 1 }
    func stop() async {}
}

private actor PersistenceRealtimeFake: RealtimeTranscribing {
    private var eventHandler: (@Sendable (TranscriptionEvent) -> Void)?
    private(set) var connectCount = 0
    func connect(apiKey: String, model: TranscriptionModel, context: String,
                 eventHandler: @escaping @Sendable (TranscriptionEvent) -> Void) async throws {
        connectCount += 1
        self.eventHandler = eventHandler
    }
    func emit(_ event: TranscriptionEvent) { eventHandler?(event) }
    func send(audioPCM16 data: Data) async {}
    func disconnect() async {}
}

private actor PersistenceAgentFake: ConversationAgentManaging {
    private let holdContext: Bool
    private let holdInvestigations: Bool
    private(set) var discoverCount = 0
    private(set) var contextCallCount = 0
    private(set) var investigationCallCount = 0
    private var contextWaiters: [Int: CheckedContinuation<AgentFinding, Error>] = [:]
    private var investigationWaiters: [CheckedContinuation<AgentFinding, Error>] = []

    init(holdContext: Bool = false, holdInvestigations: Bool = false) {
        self.holdContext = holdContext
        self.holdInvestigations = holdInvestigations
    }

    func discover(in workspace: URL) async throws -> ([CodexModel], CodexSkillsInventory) {
        discoverCount += 1
        return ([
            CodexModel(id: "context", model: "context-model", displayName: "Context", description: "", isDefault: true, hidden: false, defaultReasoningEffort: "low"),
            CodexModel(id: "deep", model: "deep-model", displayName: "Deep", description: "", isDefault: false, hidden: false, defaultReasoningEffort: "low")
        ], CodexSkillsInventory(skills: [], errors: []))
    }

    func updateContext(transcript: [TranscriptEntry], previous: AgentFinding?, workspace: URL, model: String) async throws -> AgentFinding {
        let call = contextCallCount
        contextCallCount += 1
        if holdContext {
            return try await withCheckedThrowingContinuation { contextWaiters[call] = $0 }
        }
        return finding("context-\(call)")
    }

    func investigate(selection: TranscriptSelection, question: String, surrounding: [TranscriptEntry], context: AgentFinding?, workspace: URL, model: String, id: UUID) async throws -> AgentFinding {
        investigationCallCount += 1
        if holdInvestigations {
            return try await withCheckedThrowingContinuation { investigationWaiters.append($0) }
        }
        return finding("investigation-result", tier: .deep)
    }
    func cancel(_ tier: AgentTier) async {}
    func cancelInvestigation(id: UUID) async {}
    func resetConversation() async {}
    func stop() async {}

    func completeContext(_ index: Int, title: String) {
        contextWaiters.removeValue(forKey: index)?.resume(returning: finding(title))
    }

    func completeInvestigation(title: String) {
        guard !investigationWaiters.isEmpty else { return }
        investigationWaiters.removeFirst().resume(returning: finding(title, tier: .deep))
    }

    private func finding(_ title: String, tier: AgentTier = .medium) -> AgentFinding {
        AgentFinding(id: title, title: title, summary: title, evidence: [], confidence: 1, skillsUsed: [], tier: tier)
    }
}

private actor PersistenceCodexFake: CodexAppServerRuntime {
    nonisolated let events = AsyncStream<CodexAppServerEvent> { $0.finish() }
    func start() async throws {}
    func listModels() async throws -> [CodexModel] { [] }
    func listSkills(in workspace: URL, forceReload: Bool) async throws -> CodexSkillsInventory { CodexSkillsInventory(skills: [], errors: []) }
    func startThread(_ configuration: CodexThreadConfiguration) async throws -> CodexThread { CodexThread(id: "unused", model: "unused", workspace: configuration.workspace.path) }
    func startTurn(_ configuration: CodexTurnConfiguration) async throws -> CodexTurn { CodexTurn(id: "unused", status: "completed") }
    func interrupt(threadID: String, turnID: String) async throws {}
    func stop() async {}
}

private actor FailureSessionStore: SessionStoring {
    private var records: [UUID: SavedSession] = [:]
    private var shouldFailSaves = false
    private var commitAndFail = false
    func insert(_ record: SavedSession) { records[record.id] = record }
    func failSaves(_ value: Bool) { shouldFailSaves = value }
    func commitThenFailNextSave() { commitAndFail = true }
    func save(_ record: SavedSession) async throws {
        if commitAndFail {
            commitAndFail = false
            records[record.id] = record
            throw NSError(domain: "Persistence test", code: 2)
        }
        if shouldFailSaves { throw NSError(domain: "Persistence test", code: 1) }
        records[record.id] = record
    }
    func load(id: UUID) async throws -> SessionLoadResult {
        guard let record = records[id] else { throw SessionStoreError.notFound(id) }
        return SessionLoadResult(session: record, recoveredFromBackup: false)
    }
    func list() async throws -> [SessionSummary] {
        records.values.map { record in
            SessionSummary(id: record.id, title: record.title, createdAt: record.createdAt,
                           updatedAt: record.updatedAt, preview: record.transcript.last?.text ?? "",
                           isDemo: record.isDemo)
        }
    }
    func delete(id: UUID) async throws { records[id] = nil }
}
