import Foundation
import XCTest
@testable import MurmurApp

@MainActor
final class AppModelSessionTests: XCTestCase {
    func testLiveStartupCancelledWhileRealtimeConnectIsPendingDoesNotStartCapture() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let capture = SessionCaptureFake()
        let realtime = SessionRealtimeFake()
        let model = AppModel(
            codexRuntime: SessionCodexFake(),
            userDefaults: harness.defaults,
            launchAPIKey: "test-key",
            capture: capture,
            realtime: realtime
        )
        await model.loadWorkspace(from: try harness.workspace())

        let startup = Task { await model.startLive() }
        await realtime.waitUntilConnecting(1)
        XCTAssertEqual(model.phase, .connecting)

        await model.stop()
        await realtime.resumePendingConnect(0)
        await startup.value

        XCTAssertEqual(model.phase, .idle)
        let startCount = capture.startCount
        let disconnectCount = await realtime.disconnectCount
        XCTAssertEqual(startCount, 0)
        XCTAssertGreaterThanOrEqual(disconnectCount, 1)
    }

    func testCaptureFailureEndsSessionAndDisconnectsRealtime() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let capture = SessionCaptureFake()
        let realtime = SessionRealtimeFake()
        let model = AppModel(
            codexRuntime: SessionCodexFake(),
            userDefaults: harness.defaults,
            launchAPIKey: "test-key",
            capture: capture,
            realtime: realtime
        )
        await model.loadWorkspace(from: try harness.workspace())
        let startup = Task { await model.startLive() }
        await realtime.waitUntilConnecting(1)
        await realtime.resumePendingConnect(0)
        await startup.value

        capture.fail("Microphone stopped unexpectedly")
        try await waitUntil { if case .failed = model.phase { true } else { false } }
        let disconnectCount = await realtime.disconnectCount
        XCTAssertGreaterThanOrEqual(disconnectCount, 1)
        guard case .failed(let message) = model.phase else { return XCTFail("Expected failed phase") }
        XCTAssertEqual(message, "Microphone stopped unexpectedly")
    }

    func testStaleConnectCompletionDoesNotInterruptRestartedSession() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let capture = SessionCaptureFake()
        let realtime = SessionRealtimeFake()
        let model = AppModel(
            codexRuntime: SessionCodexFake(),
            userDefaults: harness.defaults,
            launchAPIKey: "test-key",
            capture: capture,
            realtime: realtime
        )
        await model.loadWorkspace(from: try harness.workspace())

        let firstStartup = Task { await model.startLive() }
        await realtime.waitUntilConnecting(1)
        await model.stop()

        let secondStartup = Task { await model.startLive() }
        await realtime.waitUntilConnecting(2)
        await realtime.resumePendingConnect(0)
        await firstStartup.value
        XCTAssertEqual(model.phase, .connecting)
        XCTAssertEqual(capture.startCount, 0)

        await realtime.resumePendingConnect(1)
        await secondStartup.value
        XCTAssertEqual(model.phase, .listening)
        XCTAssertEqual(capture.startCount, 1)

        await realtime.emit(.partial(itemID: "old-item", delta: "stale words"), from: 0)
        await realtime.emit(.partial(itemID: "current-item", delta: "current words"), from: 1)
        try await waitUntil { model.transcript == "current words" }
        await realtime.emit(.completed(itemID: "old-item", text: "old final"), from: 0)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.transcript, "current words")

        await realtime.emit(.completed(itemID: "older-item", text: "older final"), from: 1)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.transcript, "current words")
        await model.stop()
    }

    func testStopJoinsAudioBeforeRestartAndIgnoresOldCaptureCallback() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let capture = SessionCaptureFake(), realtime = SessionRealtimeFake()
        let model = AppModel(codexRuntime: SessionCodexFake(), userDefaults: harness.defaults,
                             launchAPIKey: "test-key", capture: capture, realtime: realtime)
        await model.loadWorkspace(from: try harness.workspace())
        let start = Task { await model.startLive() }
        await realtime.waitUntilConnecting(1)
        await realtime.resumePendingConnect(0)
        await start.value
        await realtime.holdSends()
        capture.emit(Data([1, 0]), from: 0)
        try await waitUntil { await realtime.sentAudio.count == 1 }
        let stop = Task { await model.stop() }
        try await waitUntil { model.isStopping }
        await model.startLive()
        XCTAssertEqual(capture.startCount, 1, "Restart cannot begin while an old send is pending")
        XCTAssertTrue(model.isStopping)
        await realtime.releaseSend()
        await stop.value

        let restart = Task { await model.startLive() }
        await realtime.waitUntilConnecting(2)
        await realtime.resumePendingConnect(1)
        await restart.value
        capture.emit(Data([2, 0]), from: 0) // Late callback from the retired capture.
        capture.emit(Data([3, 0]), from: 1)
        try await waitUntil { await realtime.sentAudio.count >= 2 }
        await model.stop()
        let sent = await realtime.sentAudio
        XCTAssertEqual(sent, [Data([1, 0]), Data([3, 0])])
    }

    func testRecoveryNoticesPersistAndStayBetweenOldAndNewSpeech() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let capture = SessionCaptureFake(), realtime = SessionRealtimeFake()
        let model = AppModel(codexRuntime: SessionCodexFake(), userDefaults: harness.defaults,
                             launchAPIKey: "test-key", capture: capture, realtime: realtime)
        await model.loadWorkspace(from: try harness.workspace())
        let start = Task { await model.startLive() }
        await realtime.waitUntilConnecting(1); await realtime.resumePendingConnect(0); await start.value
        await realtime.emit(.committed(itemID: "old", previousItemID: nil), from: 0)
        await realtime.emit(.completed(itemID: "old", text: "Before interruption"), from: 0)
        await realtime.emit(.partial(itemID: "unfinished", delta: "unfinished words"), from: 0)
        await realtime.emit(.recovering(attempt: 1, maximum: 3), from: 0)
        await realtime.emit(.recovering(attempt: 2, maximum: 3), from: 0)
        try await waitUntil { model.transcriptionConnectionStatus?.contains("2/3") == true }
        XCTAssertEqual(model.transcriptEntries.filter(\.isSystemNotice).count, 1)
        XCTAssertTrue(model.phase.isActive)
        await realtime.emit(.recovered, from: 0)
        await realtime.emit(.committed(itemID: "new", previousItemID: nil), from: 0)
        await realtime.emit(.completed(itemID: "new", text: "After interruption"), from: 0)
        await realtime.emit(.committed(itemID: "new2", previousItemID: "new"), from: 0)
        await realtime.emit(.completed(itemID: "new2", text: "Still connected"), from: 0)
        try await waitUntil { model.transcriptEntries.last?.text == "Still connected" }
        XCTAssertEqual(model.transcriptEntries.first?.text, "Before interruption")
        let notice = try XCTUnwrap(model.transcriptEntries.first(where: \.isSystemNotice))
        XCTAssertTrue(notice.text.contains("resumed at"))
        XCTAssertEqual(model.transcriptEntries[2].id, notice.id)
        let partial = try XCTUnwrap(model.transcriptEntries.first { !$0.isFinal })
        XCTAssertEqual(partial.wasInterrupted, true)
        let restoredPartial = try JSONDecoder().decode(SavedTranscriptEntry.self, from: JSONEncoder().encode(SavedTranscriptEntry(partial)))
        XCTAssertEqual(restoredPartial.transcriptEntry.wasInterrupted, true)
        XCTAssertTrue(TranscriptTextDocument(entries: [partial]).text.contains("· interrupted"))
        XCTAssertNil(model.transcriptionConnectionStatus)
        let saved = SavedTranscriptEntry(notice)
        let restored = try JSONDecoder().decode(SavedTranscriptEntry.self, from: JSONEncoder().encode(saved)).transcriptEntry
        XCTAssertTrue(restored.isSystemNotice)
        XCTAssertEqual(restored.text, notice.text)
        let document = TranscriptTextDocument(entries: [notice])
        XCTAssertNil(document.selection(for: NSRange(location: 0, length: (document.text as NSString).length)))
        await model.stop()
    }

    func testCallOnlyStartsRunsAgentsAndReopensWithoutFolder() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let capture = SessionCaptureFake(), realtime = SessionRealtimeFake(), agents = SessionConversationFake()
        let store = InMemorySessionStore()
        let model = AppModel(codexRuntime: SessionCodexFake(), userDefaults: harness.defaults,
            launchAPIKey: "test-key", capture: capture, realtime: realtime, sessionStore: store,
            conversationAgents: agents, contextDebounceSeconds: 0, contextMinimumIntervalSeconds: 0)
        XCTAssertTrue(model.isCallOnly)
        XCTAssertTrue(model.canStartListening)
        XCTAssertFalse(model.canUseWorkspaceAgents)
        model.contextModel = "test-model"; model.deepModel = "test-model"
        model.enableCallAgents()
        let start = Task { await model.startLive() }
        await realtime.waitUntilConnecting(1); await realtime.resumePendingConnect(0); await start.value
        await realtime.emit(.completed(itemID: "one", text: "The revised delivery date is Tuesday."), from: 0)
        try await waitUntil { model.contextFinding != nil }
        let id = try XCTUnwrap(model.activeSessionID)
        let snapshot = await agents.lastSnapshot
        XCTAssertEqual(snapshot?.sessionID, id)
        XCTAssertNil(snapshot?.workspace)
        let entry = try XCTUnwrap(model.transcriptEntries.first)
        model.investigate(selection: TranscriptSelection(text: entry.text, entryIDs: [entry.id]), question: "When?")
        try await waitUntil { model.investigations.first?.finding != nil }
        await model.stop()
        let flushed = await model.prepareForQuit()
        XCTAssertTrue(flushed)
        let saved = try await store.load(id: id)
        XCTAssertNil(saved.session.workspacePath)
        let reopened = AppModel(codexRuntime: SessionCodexFake(), userDefaults: harness.defaults,
            launchAPIKey: "test-key", capture: SessionCaptureFake(), realtime: SessionRealtimeFake(), sessionStore: store)
        let opened = await reopened.openSession(id: id)
        XCTAssertTrue(opened)
        XCTAssertTrue(reopened.isCallOnly)
        XCTAssertFalse(reopened.canRelinkWorkspace)
        XCTAssertTrue(reopened.canStartListening)
        XCTAssertEqual(reopened.transcriptEntries.map(\.text), [entry.text])
        XCTAssertNotNil(reopened.investigations.first?.finding)
    }

    func testMissingLinkedFolderDoesNotBecomeCallOnly() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let store = InMemorySessionStore()
        let saved = SavedSession(workspacePath: "/nonexistent-murmur-\(UUID())", workspaceName: "Missing", transcript: [SavedTranscriptEntry(id: "e", timestamp: Date(), text: "Prior workspace conversation", isFinal: true)])
        try await store.save(saved)
        let model = AppModel(codexRuntime: SessionCodexFake(), userDefaults: harness.defaults,
            launchAPIKey: "test-key", capture: SessionCaptureFake(), realtime: SessionRealtimeFake(), sessionStore: store)
        let opened = await model.openSession(id: saved.id)
        XCTAssertTrue(opened)
        XCTAssertFalse(model.isCallOnly)
        XCTAssertTrue(model.canRelinkWorkspace)
        XCTAssertFalse(model.canStartListening)
        model.enableCallAgents()
        XCTAssertFalse(model.canUseWorkspaceAgents)
        await model.newConversation()
        XCTAssertTrue(model.isCallOnly)
    }

    func testDefaultLiveSourceIsMicrophoneOnly() {
        let harness = try! Harness()
        defer { harness.cleanUp() }
        let model = AppModel(
            codexRuntime: SessionCodexFake(),
            userDefaults: harness.defaults,
            capture: SessionCaptureFake(),
            realtime: SessionRealtimeFake()
        )

        XCTAssertEqual(model.sourceMode, .microphone)
    }

    func testTranscriptItemsStayIndependentAndFinalWinsOverLatePartial() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let capture = SessionCaptureFake(), realtime = SessionRealtimeFake()
        let model = AppModel(codexRuntime: SessionCodexFake(), userDefaults: harness.defaults,
                             launchAPIKey: "test-key", capture: capture, realtime: realtime)
        await model.loadWorkspace(from: try harness.workspace())
        let start = Task { await model.startLive() }
        await realtime.waitUntilConnecting(1); await realtime.resumePendingConnect(0); await start.value

        await realtime.emit(.committed(itemID: "first", previousItemID: nil), from: 0)
        await realtime.emit(.committed(itemID: "second", previousItemID: "first"), from: 0)
        await realtime.emit(.partial(itemID: "second", delta: "second partial"), from: 0)
        await realtime.emit(.completed(itemID: "first", text: "first final"), from: 0)
        await realtime.emit(.completed(itemID: "second", text: "second final"), from: 0)
        await realtime.emit(.partial(itemID: "second", delta: "late damage"), from: 0)
        try await waitUntil { model.transcriptEntries.filter(\.isFinal).count == 2 }

        XCTAssertTrue(model.transcriptEntries[0].text.contains("first final"))
        XCTAssertTrue(model.transcriptEntries[1].text.contains("second final"))
        XCTAssertFalse(model.transcriptEntries[1].text.contains("late damage"))
        await model.stop()
    }

    func testContextRunsForOrdinarySpeechAndStopRetainsUntilNewConversation() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let capture = SessionCaptureFake(), realtime = SessionRealtimeFake()
        let agents = SessionConversationFake()
        let model = AppModel(codexRuntime: SessionCodexFake(), userDefaults: harness.defaults,
                             launchAPIKey: "test-key", capture: capture, realtime: realtime,
                             conversationAgents: agents, contextDebounceSeconds: 0,
                             contextMinimumIntervalSeconds: 0)
        await model.loadWorkspace(from: try harness.workspace())
        model.contextModel = "test-model"
        model.deepModel = "test-model"
        model.grantAgentConsent()
        await model.refreshCodex()
        let start = Task { await model.startLive() }
        await realtime.waitUntilConnecting(1); await realtime.resumePendingConnect(0); await start.value
        await realtime.emit(.completed(itemID: "ordinary", text: "I prefer coffee in the afternoon."), from: 0)
        try await waitUntil { await agents.getContextCallCount() == 1 && model.contextFinding != nil }
        let contextCallCount = await agents.getContextCallCount()
        let lastContextEntries = await agents.getLastContextEntries()
        XCTAssertEqual(contextCallCount, 1)
        XCTAssertEqual(lastContextEntries?.first?.text, "I prefer coffee in the afternoon.")

        let transcriptBeforeStop = model.transcriptEntries
        await model.stop()
        XCTAssertEqual(model.transcriptEntries, transcriptBeforeStop)
        XCTAssertNotNil(model.contextFinding)
        await model.newConversation()
        XCTAssertTrue(model.transcriptEntries.isEmpty)
        XCTAssertNil(model.contextFinding)
    }

    func testManualContextRefreshWorksAfterStop() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let capture = SessionCaptureFake(), realtime = SessionRealtimeFake()
        let agents = SessionConversationFake()
        let model = AppModel(codexRuntime: SessionCodexFake(), userDefaults: harness.defaults,
                             launchAPIKey: "test-key", capture: capture, realtime: realtime,
                             conversationAgents: agents, contextDebounceSeconds: 0,
                             contextMinimumIntervalSeconds: 0)
        await model.loadWorkspace(from: try harness.workspace())
        model.contextModel = "test-model"
        model.deepModel = "test-model"
        model.grantAgentConsent(); await model.refreshCodex()
        let start = Task { await model.startLive() }
        await realtime.waitUntilConnecting(1); await realtime.resumePendingConnect(0); await start.value
        await realtime.emit(.completed(itemID: "one", text: "We agreed to meet Thursday."), from: 0)
        try await waitUntil { model.transcriptEntries.contains(where: \.isFinal) }
        await model.stop()
        await agents.resetContextCallCount()
        model.refreshContext()
        try await waitUntil { await agents.getContextCallCount() == 1 }
        let contextCallCount = await agents.getContextCallCount()
        XCTAssertEqual(contextCallCount, 1)
        await model.stop()
    }
}

private final class Harness {
    let defaults: UserDefaults
    private let root: URL

    init() throws {
        let suite = "AppModelSessionTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func workspace() throws -> URL {
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try "# Test workspace".write(
            to: workspace.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        return workspace
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
private final class SessionCaptureFake: AudioCaptureManaging {
    private(set) var startCount = 0
    private var errorHandler: (@Sendable (String) -> Void)?
    private var audioHandlers: [@Sendable (Data) -> Void] = []

    func start(
        mode: AudioSourceMode,
        audioHandler: @escaping @Sendable (Data) -> Void,
        errorHandler: (@Sendable (String) -> Void)?
    ) async throws {
        startCount += 1
        self.errorHandler = errorHandler
        audioHandlers.append(audioHandler)
    }

    func stop() async {}

    func fail(_ message: String) { errorHandler?(message) }
    func emit(_ data: Data, from index: Int) { audioHandlers[index](data) }
}

private actor SessionRealtimeFake: RealtimeTranscribing {
    private var connectContinuations: [CheckedContinuation<Void, Never>] = []
    private var connectedWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var connectCount = 0
    private var eventHandlers: [@Sendable (TranscriptionEvent) -> Void] = []
    private(set) var disconnectCount = 0

    func connect(
        apiKey: String,
        model: TranscriptionModel,
        context: String,
        eventHandler: @escaping @Sendable (TranscriptionEvent) -> Void
    ) async throws {
        connectCount += 1
        let currentCount = connectCount
        eventHandlers.append(eventHandler)
        let ready = connectedWaiters.filter { $0.0 <= currentCount }
        connectedWaiters.removeAll { $0.0 <= currentCount }
        ready.forEach { $0.1.resume() }
        await withCheckedContinuation { connectContinuations.append($0) }
    }

    private(set) var sentAudio: [Data] = []
    private var shouldHoldSends = false
    private var pendingSend: CheckedContinuation<Void, Never>?
    func holdSends() { shouldHoldSends = true }
    func releaseSend() {
        shouldHoldSends = false
        pendingSend?.resume()
        pendingSend = nil
    }
    func send(audioPCM16 data: Data) async {
        sentAudio.append(data)
        if shouldHoldSends { await withCheckedContinuation { pendingSend = $0 } }
    }

    func disconnect() async {
        disconnectCount += 1
    }

    func waitUntilConnecting(_ expectedCount: Int) async {
        if connectCount >= expectedCount { return }
        await withCheckedContinuation { connectedWaiters.append((expectedCount, $0)) }
    }

    func resumePendingConnect(_ index: Int) {
        connectContinuations[index].resume()
    }

    func emit(_ event: TranscriptionEvent, from index: Int) {
        eventHandlers[index](event)
    }
}

@MainActor
private func waitUntil(
    iterations: Int = 1_000,
    condition: @MainActor () async -> Bool
) async throws {
    for _ in 0..<iterations {
        if await condition() { return }
        await Task.yield()
    }
    XCTFail("Condition did not become true")
}

private actor SessionCodexFake: CodexAppServerRuntime {
    nonisolated let events = AsyncStream<CodexAppServerEvent> { $0.finish() }

    func start() async throws {}
    func listModels() async throws -> [CodexModel] { [] }
    func listSkills(in workspace: URL, forceReload: Bool) async throws -> CodexSkillsInventory {
        CodexSkillsInventory(skills: [], errors: [])
    }
    func startThread(_ configuration: CodexThreadConfiguration) async throws -> CodexThread {
        CodexThread(id: "unused", model: "unused", workspace: configuration.workspace.path)
    }
    func startTurn(_ configuration: CodexTurnConfiguration) async throws -> CodexTurn {
        CodexTurn(id: "unused", status: "completed")
    }
    func interrupt(threadID: String, turnID: String) async throws {}
    func stop() async {}
}

private actor SessionConversationFake: ConversationAgentManaging {
    private(set) var contextCallCount = 0
    private(set) var lastContextEntries: [TranscriptEntry]?

    func discover(in workspace: URL) async throws -> ([CodexModel], CodexSkillsInventory) {
        ([CodexModel(id: "test-model", model: "test-model", displayName: "Test", description: "", isDefault: true, hidden: false, defaultReasoningEffort: "medium")], CodexSkillsInventory(skills: [], errors: []))
    }
    func updateContext(transcript: [TranscriptEntry], previous: AgentFinding?, workspace: URL, model: String) async throws -> AgentFinding {
        contextCallCount += 1
        lastContextEntries = transcript
        return AgentFinding(id: "context-\(contextCallCount)", title: "Call context", summary: "Understanding: team prefers coffee. Decisions: none. Questions: none.", evidence: [], confidence: 0.8, skillsUsed: [], tier: .medium)
    }
    func investigate(selection: TranscriptSelection, question: String, surrounding: [TranscriptEntry], context: AgentFinding?, workspace: URL, model: String, id: UUID) async throws -> AgentFinding {
        AgentFinding(id: "investigation-\(id)", title: "Passage finding", summary: question, evidence: [], confidence: 0.8, skillsUsed: [], tier: .deep)
    }
    private(set) var lastSnapshot: CallContextSnapshot?
    func updateContext(snapshot: CallContextSnapshot, previous: AgentFinding?, model: String) async throws -> AgentFinding {
        lastSnapshot = snapshot
        contextCallCount += 1
        lastContextEntries = snapshot.entries
        return AgentFinding(id: "context", title: "Call", summary: "Spoken: delivery Tuesday", evidence: [], confidence: 0.8, skillsUsed: [], tier: .medium)
    }
    func investigate(selection: TranscriptSelection, question: String, snapshot: CallContextSnapshot, context: AgentFinding?, model: String, id: UUID) async throws -> AgentFinding {
        lastSnapshot = snapshot
        return AgentFinding(id: id.uuidString, title: "Passage", summary: "Tuesday was stated.", evidence: [], confidence: 0.8, skillsUsed: [], tier: .deep)
    }
    func cancel(_ tier: AgentTier) async {}
    func cancelInvestigation(id: UUID) async {}
    func resetConversation() async {}
    func stop() async {}
    func resetContextCallCount() { contextCallCount = 0 }
    func getContextCallCount() -> Int { contextCallCount }
    func getLastContextEntries() -> [TranscriptEntry]? { lastContextEntries }
}
