#if canImport(CoreMedia)
import CoreMedia
#endif
import Foundation
import XCTest
@testable import MurmurCore

@MainActor
final class AppModelPostCallLifecycleTests: XCTestCase {
    func testFailedFinalTranscriptSaveKeepsTemporaryRecording() async throws {
        let harness = try LifecycleHarness()
        defer { harness.cleanUp() }
        let store = LifecycleSessionStore(failWhenContextPending: true)
        let capture = LifecycleCapture()
        let realtime = LifecycleRealtime()
        let transcriber = LifecycleBatchTranscriber()
        let model = harness.model(store: store, capture: capture, realtime: realtime, transcriber: transcriber)
        configureAgents(model)
        model.setBatchTranscriptionModel("test-batch")
        await start(model, realtime: realtime, capture: capture, itemID: "live-a")
        XCTAssertEqual(model.phase, .listening)
        XCTAssertEqual(model.postCallStatus, "recording")
        XCTAssertEqual(model.postCallRecordingIDs.count, 1)
        await model.stop()

        try await waitUntil { model.postCallStatus == "failed" }
        let recordingID = try XCTUnwrap(model.postCallRecordingIDs.first)
        let manifest = try await harness.recordingStore.manifest(sessionID: recordingID)
        XCTAssertTrue(manifest.isComplete)
        XCTAssertFalse(manifest.chunks.isEmpty)
        XCTAssertTrue(model.transcriptEntries.contains { $0.id.hasPrefix("postcall:") && $0.text == "Final 1." })
        let requests = await transcriber.requestCount
        XCTAssertEqual(requests, 1)
    }

    func testDeletesRecordingOnlyAfterMatchingContextIsPersisted() async throws {
        let harness = try LifecycleHarness()
        defer { harness.cleanUp() }
        let store = LifecycleSessionStore()
        let capture = LifecycleCapture()
        let realtime = LifecycleRealtime()
        let transcriber = LifecycleBatchTranscriber()
        let agents = LifecycleAgents(holdContextUpdates: true)
        let model = harness.model(store: store, capture: capture, realtime: realtime,
                                  transcriber: transcriber, agents: agents)
        await start(model, realtime: realtime, capture: capture, itemID: "live-success")
        await model.stop()
        try await waitUntil { model.postCallStatus == "pending" }
        configureAgents(model)
        model.setBatchTranscriptionModel("test-batch")
        model.retryPostCallReview()
        try await waitUntil { model.postCallStatus == "context_pending" }
        await agents.waitUntilContextStarted()

        let sessionID = try XCTUnwrap(model.activeSessionID)
        let recordingID = try XCTUnwrap(model.postCallRecordingIDs.first)
        let recordingFolder = harness.recordingStore.checkpointRootURL.appendingPathComponent(recordingID.uuidString, isDirectory: true)
        let checkpoint = recordingFolder.appendingPathComponent("transcription-checkpoint.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordingFolder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpoint.path))
        XCTAssertTrue(model.postCallTranscriptEntries.contains { $0.id.hasSuffix(":live-success") })
        XCTAssertTrue(model.transcriptEntries.contains { $0.id.hasPrefix("postcall:") && $0.text == "Final 1." })
        let beforeContextSave = try await store.load(id: sessionID)
        XCTAssertEqual(beforeContextSave.session.postCallStatus, "context_pending")
        XCTAssertNil(beforeContextSave.session.context)

        await agents.releaseContextUpdates()
        try await waitUntil { model.postCallStatus == "complete" }
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordingFolder.path))
        let saved = try await waitForSavedStatus("complete", id: sessionID, store: store)
        XCTAssertEqual(saved.session.postCallStatus, "complete")
        XCTAssertNotNil(saved.session.context)
        XCTAssertEqual(saved.session.contextTranscriptRevision, saved.session.transcriptRevision)
        XCTAssertTrue(saved.session.postCallTranscript?.contains { $0.id.hasSuffix(":live-success") } == true)
        XCTAssertEqual(saved.session.transcript.filter { $0.id.hasPrefix("postcall:") }.map(\.text), ["Final 1."])
        XCTAssertNil(saved.session.postCallRecordingIDs)
    }

    func testReopenedPendingReviewKeepsLiveAndFinalTranscriptWithoutDuplicates() async throws {
        let harness = try LifecycleHarness()
        defer { harness.cleanUp() }
        let store = LifecycleSessionStore()
        let firstCapture = LifecycleCapture()
        let firstRealtime = LifecycleRealtime()
        let transcriber = LifecycleBatchTranscriber()
        let first = harness.model(store: store, capture: firstCapture, realtime: firstRealtime, transcriber: transcriber)
        first.setKeepRecordingUntilReviewed(true)
        await start(first, realtime: firstRealtime, capture: firstCapture, itemID: "live-original")
        await first.stop() // No batch model yet, so the saved session is pending.
        let sessionID = try XCTUnwrap(first.activeSessionID)
        try await waitUntil { first.postCallStatus == "pending" }
        let savedPending = try await store.load(id: sessionID)
        XCTAssertEqual(savedPending.session.postCallStatus, "pending")
        XCTAssertEqual(savedPending.session.postCallRecordingIDs?.count, 1)

        let reopenedCapture = LifecycleCapture()
        let reopenedRealtime = LifecycleRealtime()
        let reopened = harness.model(store: store, capture: reopenedCapture, realtime: reopenedRealtime, transcriber: transcriber)
        let didOpen = await reopened.openSession(id: sessionID)
        XCTAssertTrue(didOpen)
        configureAgents(reopened)
        reopened.setBatchTranscriptionModel("test-batch")
        reopened.retryPostCallReview()
        try await waitUntil { reopened.postCallStatus == "retained" }

        XCTAssertTrue(reopened.postCallTranscriptEntries.contains { $0.id.hasSuffix(":live-original") })
        XCTAssertEqual(reopened.transcriptEntries.filter { $0.id.hasPrefix("postcall:") }.count, 1)
        XCTAssertEqual(Set(reopened.transcriptEntries.map(\.id)).count, reopened.transcriptEntries.count)
        let requestsAfterFirstReview = await transcriber.requestCount
        XCTAssertEqual(requestsAfterFirstReview, 1)
        let recordingID = try XCTUnwrap(reopened.postCallRecordingIDs.first)
        let firstManifest = try await harness.recordingStore.manifest(sessionID: recordingID)
        XCTAssertTrue(firstManifest.isComplete)

        // A second explicit review resumes from its checkpoint instead of charging again
        // or appending the same final entry twice.
        reopened.retryPostCallReview(userInitiated: true)
        try await waitUntil { reopened.postCallStatus == "retained" }
        let requestsAfterRetry = await transcriber.requestCount
        XCTAssertEqual(requestsAfterRetry, 1)
        XCTAssertEqual(reopened.transcriptEntries.filter { $0.id.hasPrefix("postcall:") }.count, 1)
        XCTAssertEqual(reopened.postCallTranscriptEntries.filter { $0.id.hasSuffix(":live-original") }.count, 1)
    }

    func testSwitchingSessionCancelsStalePostCallResult() async throws {
        let harness = try LifecycleHarness()
        defer { harness.cleanUp() }
        let store = LifecycleSessionStore()
        let capture = LifecycleCapture()
        let realtime = LifecycleRealtime()
        let transcriber = LifecycleBatchTranscriber(delay: .seconds(10))
        let model = harness.model(store: store, capture: capture, realtime: realtime, transcriber: transcriber)
        await start(model, realtime: realtime, capture: capture, itemID: "live-stale")
        await model.stop()
        let originalID = try XCTUnwrap(model.activeSessionID)
        try await waitUntil { model.postCallStatus == "pending" }
        let destination = SavedSession(id: UUID(), title: "Destination", transcript: [
            SavedTranscriptEntry(id: "destination-entry", timestamp: Date(), text: "Destination only", isFinal: true)
        ])
        try await store.save(destination)

        configureAgents(model)
        model.setBatchTranscriptionModel("test-batch")
        model.retryPostCallReview()
        try await waitUntil { await transcriber.requestCount == 1 }
        let didOpen = await model.openSession(id: destination.id)
        XCTAssertTrue(didOpen)
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(model.activeSessionID, destination.id)
        XCTAssertEqual(model.transcriptEntries.map(\.text), ["Destination only"])
        XCTAssertFalse(model.transcriptEntries.contains { $0.id.hasPrefix("postcall:") })
        let original = try await store.load(id: originalID)
        XCTAssertEqual(original.session.postCallStatus, "pending")
        XCTAssertEqual(original.session.postCallRecordingIDs?.count, 1)
        let originalRecordingID = try XCTUnwrap(original.session.postCallRecordingIDs?.first)
        let originalManifest = try await harness.recordingStore.manifest(sessionID: originalRecordingID)
        XCTAssertFalse(originalManifest.chunks.isEmpty)
    }

    func testStopResumeKeepsEachCaptureAndFinalizesBothRecordings() async throws {
        let harness = try LifecycleHarness()
        defer { harness.cleanUp() }
        let store = LifecycleSessionStore()
        let capture = LifecycleCapture()
        let realtime = LifecycleRealtime()
        let transcriber = LifecycleBatchTranscriber()
        let model = harness.model(store: store, capture: capture, realtime: realtime, transcriber: transcriber)
        model.setKeepRecordingUntilReviewed(true)
        await start(model, realtime: realtime, capture: capture, itemID: "live-first")
        await model.stop()
        try await waitUntil { model.postCallStatus == "pending" }
        let originalSessionID = try XCTUnwrap(model.activeSessionID)
        XCTAssertEqual(model.postCallRecordingIDs.count, 1)

        await start(model, realtime: realtime, capture: capture, itemID: "live-second")
        configureAgents(model)
        model.setBatchTranscriptionModel("test-batch")
        await model.stop()
        try await waitUntil { model.postCallStatus == "retained" }

        XCTAssertEqual(model.activeSessionID, originalSessionID)
        XCTAssertEqual(model.postCallRecordingIDs.count, 2)
        let requests = await transcriber.requestCount
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(model.transcriptEntries.filter { $0.id.hasPrefix("postcall:") }.count, 2)
        for recordingID in model.postCallRecordingIDs {
            let manifest = try await harness.recordingStore.manifest(sessionID: recordingID)
            XCTAssertTrue(manifest.isComplete)
        }
    }

    private func configureAgents(_ model: AppModel) {
        model.contextModel = "test-context"
        model.enableCallAgents()
    }

    private func start(
        _ model: AppModel,
        realtime: LifecycleRealtime,
        capture: LifecycleCapture,
        itemID: String
    ) async {
        let task = Task { await model.startLive() }
        await realtime.waitUntilConnected()
        await task.value
        capture.emitRecording(samples: 2_400, atSample: 0)
        await realtime.emit(.completed(itemID: itemID, text: "Original live (itemID)."))
        try? await waitUntil { model.transcriptEntries.contains { $0.id.hasSuffix(":" + itemID) && $0.isFinal } }
    }

    private func waitUntil(
        iterations: Int = 500,
        condition: @MainActor () async -> Bool
    ) async throws {
        for _ in 0..<iterations {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition did not become true")
    }

    private func waitForSavedStatus(_ status: String, id: UUID, store: LifecycleSessionStore) async throws -> SessionLoadResult {
        for _ in 0..<500 {
            if let loaded = try? await store.load(id: id), loaded.session.postCallStatus == status { return loaded }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Saved session did not reach status \(status)")
        throw SessionStoreError.notFound(id)
    }
}

private struct LifecycleHarness {
    let root: URL
    let defaults: UserDefaults
    let recordingStore: AudioRecordingStore
    private let suite: String

    init() throws {
        suite = "AppModelPostCallLifecycleTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "temporaryRecordingEnabled")
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        recordingStore = AudioRecordingStore(rootURL: root.appendingPathComponent("recordings", isDirectory: true))
    }

    @MainActor
    func model(
        store: any SessionStoring,
        capture: LifecycleCapture,
        realtime: LifecycleRealtime,
        transcriber: LifecycleBatchTranscriber,
        agents: LifecycleAgents = LifecycleAgents()
    ) -> AppModel {
        let checkpointStore = JSONPostCallTranscriptionCheckpointStore(directory: recordingStore.checkpointRootURL)
        let postCall = PostCallTranscriptionCoordinator(transcriber: transcriber, checkpointStore: checkpointStore)
        return AppModel(
            codexRuntime: LifecycleRuntime(), userDefaults: defaults, launchAPIKey: "fixture-key",
            capture: capture, realtime: realtime, sessionStore: store, recordingStore: recordingStore,
            postCallCoordinator: postCall, conversationAgents: agents,
            contextDebounceSeconds: 0, contextMinimumIntervalSeconds: 0
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor
private final class LifecycleCapture: AudioCaptureManaging {
    private var recordingSessionID: UUID?
    private var recordingHandler: (@Sendable (UUID, AudioRecordingSource, Data, MediaTime) -> Void)?

    func start(mode: AudioSourceMode, audioHandler: @escaping @Sendable (Data) -> Void,
               errorHandler: (@Sendable (String) -> Void)?) async throws {}

    func start(mode: AudioSourceMode, audioHandler: @escaping @Sendable (Data) -> Void,
               errorHandler: (@Sendable (String) -> Void)?, recordingSessionID: UUID?,
               recordingHandler: (@Sendable (UUID, AudioRecordingSource, Data, MediaTime) -> Void)?) async throws {
        self.recordingSessionID = recordingSessionID
        self.recordingHandler = recordingHandler
    }

    func stop() async {}

    func emitRecording(samples: Int, atSample: Int64) {
        guard let recordingSessionID, let recordingHandler else { return }
        var data = Data(capacity: samples * 2)
        for _ in 0..<samples { data.append(0xE8); data.append(0x03) }
        recordingHandler(recordingSessionID, .microphone, data, MediaTime(value: atSample, timescale: 24_000))
    }
}

private actor LifecycleRealtime: RealtimeTranscribing {
    private var eventHandler: (@Sendable (TranscriptionEvent) -> Void)?
    private var connectedWaiters: [CheckedContinuation<Void, Never>] = []
    private var isConnected = false

    func connect(apiKey: String, model: TranscriptionModel, context: String,
                 eventHandler: @escaping @Sendable (TranscriptionEvent) -> Void) async throws {
        self.eventHandler = eventHandler
        isConnected = true
        connectedWaiters.forEach { $0.resume() }
        connectedWaiters.removeAll()
    }

    func waitUntilConnected() async {
        if isConnected { return }
        await withCheckedContinuation { connectedWaiters.append($0) }
    }

    func emit(_ event: TranscriptionEvent) { eventHandler?(event) }
    func send(audioPCM16 data: Data) async {}
    func disconnect() async { isConnected = false }
}

private actor LifecycleBatchTranscriber: BatchAudioTranscribing {
    private var count = 0
    private let delay: Duration
    init(delay: Duration = .zero) { self.delay = delay }
    var requestCount: Int { count }

    func transcribe(fileURL: URL, fileName: String, model: String) async throws -> PostCallBatchTranscript {
        count += 1
        if delay != .zero { try await Task.sleep(for: delay) }
        let audio = try Data(contentsOf: fileURL)
        guard audio.count > 44 else { throw OpenAIBatchTranscriptionError.invalidAudioFile }
        return PostCallBatchTranscript(text: "Final \(count).")
    }
}

private actor LifecycleAgents: ConversationAgentManaging {
    private var contextCount = 0
    private let holdContextUpdates: Bool
    private var contextStarted = false
    private var contextStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContext: CheckedContinuation<Void, Never>?
    init(holdContextUpdates: Bool = false) { self.holdContextUpdates = holdContextUpdates }
    func discover(in workspace: URL) async throws -> ([CodexModel], CodexSkillsInventory) { ([], CodexSkillsInventory(skills: [], errors: [])) }
    func updateContext(transcript: [TranscriptEntry], previous: AgentFinding?, workspace: URL, model: String) async throws -> AgentFinding {
        finding("context")
    }
    func investigate(selection: TranscriptSelection, question: String, surrounding: [TranscriptEntry], context: AgentFinding?, workspace: URL, model: String, id: UUID) async throws -> AgentFinding {
        finding("investigation")
    }
    func updateContext(snapshot: CallContextSnapshot, previous: AgentFinding?, model: String) async throws -> AgentFinding {
        contextCount += 1
        contextStarted = true
        contextStartWaiters.forEach { $0.resume() }
        contextStartWaiters.removeAll()
        if holdContextUpdates && contextCount == 1 {
            await withCheckedContinuation { releaseContext = $0 }
        }
        return finding("context-\(contextCount)")
    }
    func waitUntilContextStarted() async {
        if contextStarted { return }
        await withCheckedContinuation { contextStartWaiters.append($0) }
    }
    func releaseContextUpdates() { releaseContext?.resume(); releaseContext = nil }
    func investigate(selection: TranscriptSelection, question: String, snapshot: CallContextSnapshot, context: AgentFinding?, model: String, id: UUID) async throws -> AgentFinding {
        finding("investigation")
    }
    func cancel(_ tier: AgentTier) async {}
    func cancelInvestigation(id: UUID) async {}
    func resetConversation() async {}
    func stop() async {}

    private func finding(_ id: String) -> AgentFinding {
        AgentFinding(id: id, title: "Context", summary: "Reviewed.", evidence: [], confidence: 1, skillsUsed: [], tier: .medium)
    }
}

private actor LifecycleSessionStore: SessionStoring {
    private var sessions: [UUID: SavedSession] = [:]
    private let failWhenContextPending: Bool

    init(failWhenContextPending: Bool = false) { self.failWhenContextPending = failWhenContextPending }

    func save(_ record: SavedSession) throws {
        if failWhenContextPending && record.postCallStatus == "context_pending" {
            throw NSError(domain: "LifecycleSessionStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Injected final save failure"])
        }
        sessions[record.id] = record
    }

    func load(id: UUID) throws -> SessionLoadResult {
        guard let session = sessions[id] else { throw SessionStoreError.notFound(id) }
        return SessionLoadResult(session: session, recoveredFromBackup: false)
    }

    func list() -> [SessionSummary] {
        sessions.values.map { record in
            SessionSummary(id: record.id, title: record.title, createdAt: record.createdAt, updatedAt: record.updatedAt,
                           preview: record.transcript.last?.text ?? "", isDemo: record.isDemo)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func delete(id: UUID) throws {
        guard sessions.removeValue(forKey: id) != nil else { throw SessionStoreError.notFound(id) }
    }
}

private struct LifecycleRuntime: CodexAppServerRuntime {
    var events: AsyncStream<CodexAppServerEvent> { AsyncStream { $0.finish() } }
    func start() async throws {}
    func listModels() async throws -> [CodexModel] { [] }
    func listSkills(in workspace: URL, forceReload: Bool) async throws -> CodexSkillsInventory { CodexSkillsInventory(skills: [], errors: []) }
    func startThread(_ configuration: CodexThreadConfiguration) async throws -> CodexThread { CodexThread(id: "", model: "", workspace: "") }
    func startTurn(_ configuration: CodexTurnConfiguration) async throws -> CodexTurn { CodexTurn(id: "", status: "completed") }
    func interrupt(threadID: String, turnID: String) async throws {}
    func stop() async {}
}
