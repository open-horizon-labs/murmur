import Foundation
import XCTest
@testable import MurmurApp

@MainActor
final class ConversationSchedulingTests: XCTestCase {
    func testFinalsDuringContextRunCoalesceIntoOneLatestRunWithPriorFinding() async throws {
        let harness = try SchedulingHarness()
        defer { harness.cleanUp() }
        let agents = HeldContextAgentFake()
        let realtime = SchedulingRealtimeFake()
        let model = try await harness.makeModel(agents: agents, realtime: realtime)
        await startListening(model, realtime: realtime)

        await realtime.emit(.completed(itemID: "a", text: "first utterance"))
        try await waitUntilScheduling { await agents.callCount == 1 }
        await realtime.emit(.completed(itemID: "b", text: "second utterance"))
        await realtime.emit(.completed(itemID: "c", text: "third utterance"))
        try await waitUntilScheduling { model.transcriptEntries.filter(\.isFinal).count == 3 }

        await agents.complete(0, finding: finding("context-1"))
        try await waitUntilScheduling { await agents.callCount == 2 }
        let latest = await agents.call(at: 1)
        XCTAssertEqual(latest.transcript.map(\.text), ["first utterance", "second utterance", "third utterance"])
        XCTAssertEqual(latest.previous?.id, "context-1")
        let maximumConcurrentCalls = await agents.getMaximumConcurrentCalls()
        XCTAssertEqual(maximumConcurrentCalls, 1)

        await agents.complete(1, finding: finding("context-2"))
        try await waitUntilScheduling { model.contextFinding?.id == "context-2" }
        await model.stop()
    }

    func testStopResumeRejectsOldResultAndNewConversationDoesNotReusePendingTranscript() async throws {
        let harness = try SchedulingHarness()
        defer { harness.cleanUp() }
        let agents = HeldContextAgentFake()
        let realtime = SchedulingRealtimeFake()
        let model = try await harness.makeModel(agents: agents, realtime: realtime)
        await startListening(model, realtime: realtime)

        await realtime.emit(.completed(itemID: "old-a", text: "older utterance"))
        try await waitUntilScheduling { await agents.callCount == 1 }
        await realtime.emit(.completed(itemID: "old-b", text: "newer utterance"))
        try await waitUntilScheduling { model.transcriptEntries.filter(\.isFinal).count == 2 }
        await model.stop()

        await startListening(model, realtime: realtime)
        try await waitUntilScheduling { await agents.callCount == 2 }
        let resumed = await agents.call(at: 1)
        XCTAssertEqual(resumed.transcript.map(\.text), ["older utterance", "newer utterance"])

        await agents.complete(0, finding: finding("stale-context"))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(model.contextFinding, "A late result from before Stop must not publish.")
        await agents.complete(1, finding: finding("resumed-context"))
        try await waitUntilScheduling { model.contextFinding?.id == "resumed-context" }
        await model.stop()

        await model.newConversation()
        XCTAssertTrue(model.transcriptEntries.isEmpty)
        XCTAssertNil(model.contextFinding)
        await startListening(model, realtime: realtime)
        for _ in 0..<20 { await Task.yield() }
        let callCountAfterNew = await agents.getCallCount()
        XCTAssertEqual(callCountAfterNew, 2, "New must not dispatch Context using the prior conversation's transcript.")
        XCTAssertTrue(model.transcriptEntries.isEmpty)
        await model.stop()
    }

    func testCallSnapshotCannotFollowUIIntoAnotherSessionOrFolder() async throws {
        let harness = try SchedulingHarness()
        defer { harness.cleanUp() }
        let agents = HeldContextAgentFake()
        let realtime = SchedulingRealtimeFake()
        let model = try await harness.makeModel(agents: agents, realtime: realtime)
        model.useCallOnly()
        model.enableCallAgents()
        await startListening(model, realtime: realtime)
        await realtime.emit(.completed(itemID: "a", text: "FIRST_CALL_CANARY"))
        try await waitUntilScheduling { await agents.callCount == 1 }
        let firstValue = await agents.snapshot(at: 0)
        let first = try XCTUnwrap(firstValue)
        await model.stop()
        await model.newConversation()
        await startListening(model, realtime: realtime)
        await realtime.emit(.completed(itemID: "b", text: "SECOND_CALL_CANARY"))
        try await waitUntilScheduling { await agents.callCount == 2 }
        let secondValue = await agents.snapshot(at: 1)
        let second = try XCTUnwrap(secondValue)
        XCTAssertNotEqual(first.sessionID, second.sessionID)
        XCTAssertNil(first.workspace)
        XCTAssertNil(second.workspace)
        XCTAssertEqual(first.entries.map(\.text), ["FIRST_CALL_CANARY"])
        XCTAssertEqual(second.entries.map(\.text), ["SECOND_CALL_CANARY"])
        await agents.complete(0, finding: finding("stale-first-call"))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNotEqual(model.contextFinding?.id, "stale-first-call")
        await agents.complete(1, finding: finding("second-call"))
        try await waitUntilScheduling { model.contextFinding?.id == "second-call" }
        await model.stop()
    }

    func testDisablingCallAgentsClearsBusyStateAndRejectsLateResult() async throws {
        let harness = try SchedulingHarness()
        defer { harness.cleanUp() }
        let agents = HeldContextAgentFake()
        let realtime = SchedulingRealtimeFake()
        let model = try await harness.makeModel(agents: agents, realtime: realtime)
        model.useCallOnly()
        model.enableCallAgents()
        await startListening(model, realtime: realtime)
        await realtime.emit(.completed(itemID: "a", text: "A decision to inspect"))
        try await waitUntilScheduling { await agents.callCount == 1 }
        XCTAssertEqual(model.mediumActivity, .working)
        model.disableCallAgents()
        XCTAssertEqual(model.mediumActivity, .idle)
        XCTAssertFalse(model.canUseWorkspaceAgents)
        await agents.complete(0, finding: finding("late-disabled-result"))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(model.contextFinding)
        model.enableCallAgents()
        XCTAssertTrue(model.canUseWorkspaceAgents)
        XCTAssertNotEqual(model.mediumActivity, .working)
        await model.stop()
    }

    private func startListening(_ model: AppModel, realtime: SchedulingRealtimeFake) async {
        await model.startLive()
        XCTAssertEqual(model.phase, .listening)
    }

    private func finding(_ id: String) -> AgentFinding {
        AgentFinding(id: id, title: id, summary: id, evidence: [], confidence: 1, skillsUsed: [], tier: .medium)
    }
}

private struct ScheduledContextCall: Sendable {
    let transcript: [TranscriptEntry]
    let previous: AgentFinding?
}

private actor HeldContextAgentFake: ConversationAgentManaging {
    private(set) var calls: [ScheduledContextCall] = []
    private var snapshots: [Int: CallContextSnapshot] = [:]

    func snapshot(at index: Int) -> CallContextSnapshot? { snapshots[index] }

    func updateContext(snapshot: CallContextSnapshot, previous: AgentFinding?, model: String) async throws -> AgentFinding {
        snapshots[calls.count] = snapshot
        return try await updateContext(transcript: snapshot.entries, previous: previous, workspace: snapshot.workspace ?? URL(fileURLWithPath: "/unused"), model: model)
    }
    private(set) var maximumConcurrentCalls = 0
    private var activeCalls = 0
    private var pending: [Int: CheckedContinuation<AgentFinding, Error>] = [:]
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    var callCount: Int { calls.count }

    func getCallCount() -> Int { calls.count }
    func getMaximumConcurrentCalls() -> Int { maximumConcurrentCalls }

    func discover(in workspace: URL) async throws -> ([CodexModel], CodexSkillsInventory) {
        ([CodexModel(id: "test", model: "test", displayName: "Test", description: "", isDefault: true, hidden: false, defaultReasoningEffort: "low")], CodexSkillsInventory(skills: [], errors: []))
    }

    func updateContext(transcript: [TranscriptEntry], previous: AgentFinding?, workspace: URL, model: String) async throws -> AgentFinding {
        let index = calls.count
        calls.append(ScheduledContextCall(transcript: transcript, previous: previous))
        activeCalls += 1
        maximumConcurrentCalls = max(maximumConcurrentCalls, activeCalls)
        resumeCountWaiters()
        let result = try await withCheckedThrowingContinuation { pending[index] = $0 }
        activeCalls -= 1
        return result
    }

    func investigate(selection: TranscriptSelection, question: String, surrounding: [TranscriptEntry], context: AgentFinding?, workspace: URL, model: String, id: UUID) async throws -> AgentFinding {
        AgentFinding(id: "unused-\(id)", title: question, summary: selection.text, evidence: [], confidence: 1, skillsUsed: [], tier: .deep)
    }

    func cancel(_ tier: AgentTier) async {}
    func cancelInvestigation(id: UUID) async {}
    func resetConversation() async {}
    func stop() async {}

    func waitForCallCount(_ expected: Int) async {
        if calls.count >= expected { return }
        await withCheckedContinuation { countWaiters.append((expected, $0)) }
    }

    func call(at index: Int) -> ScheduledContextCall { calls[index] }

    func complete(_ index: Int, finding: AgentFinding) {
        pending.removeValue(forKey: index)?.resume(returning: finding)
    }

    private func resumeCountWaiters() {
        let ready = countWaiters.filter { calls.count >= $0.0 }
        countWaiters.removeAll { calls.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
}

@MainActor
private final class SchedulingCaptureFake: AudioCaptureManaging {
    func start(mode: AudioSourceMode, audioHandler: @escaping @Sendable (Data) -> Void, errorHandler: (@Sendable (String) -> Void)?) async throws {}
    func stop() async {}
}

private actor SchedulingRealtimeFake: RealtimeTranscribing {
    private var eventHandler: (@Sendable (TranscriptionEvent) -> Void)?

    func connect(apiKey: String, model: TranscriptionModel, context: String, eventHandler: @escaping @Sendable (TranscriptionEvent) -> Void) async throws {
        self.eventHandler = eventHandler
    }

    func emit(_ event: TranscriptionEvent) { eventHandler?(event) }
    func send(audioPCM16 data: Data) async {}
    func disconnect() async {}
}

@MainActor
private final class SchedulingHarness {
    private let root: URL
    private let defaults: UserDefaults
    private let suite: String

    init() throws {
        suite = "ConversationSchedulingTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func makeModel(agents: HeldContextAgentFake, realtime: SchedulingRealtimeFake) async throws -> AppModel {
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try "# Scheduling fixture".write(to: workspace.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let model = AppModel(
            codexRuntime: UnusedSchedulingRuntime(), userDefaults: defaults,
            launchAPIKey: "test-key", capture: SchedulingCaptureFake(), realtime: realtime,
            conversationAgents: agents, contextDebounceSeconds: 0, contextMinimumIntervalSeconds: 0
        )
        await model.loadWorkspace(from: workspace)
        model.contextModel = "test"
        model.deepModel = "test"
        model.grantAgentConsent()
        await model.refreshCodex()
        return model
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

private actor UnusedSchedulingRuntime: CodexAppServerRuntime {
    nonisolated let events = AsyncStream<CodexAppServerEvent> { $0.finish() }
    func start() async throws {}
    func listModels() async throws -> [CodexModel] { [] }
    func listSkills(in workspace: URL, forceReload: Bool) async throws -> CodexSkillsInventory { CodexSkillsInventory(skills: [], errors: []) }
    func startThread(_ configuration: CodexThreadConfiguration) async throws -> CodexThread { CodexThread(id: "unused", model: "unused", workspace: configuration.workspace.path) }
    func startTurn(_ configuration: CodexTurnConfiguration) async throws -> CodexTurn { CodexTurn(id: "unused", status: "completed") }
    func interrupt(threadID: String, turnID: String) async throws {}
    func stop() async {}
}

@MainActor
private func waitUntilScheduling(iterations: Int = 2_000, condition: @MainActor () async -> Bool) async throws {
    for _ in 0..<iterations {
        if await condition() { return }
        await Task.yield()
    }
    XCTFail("Scheduling condition did not become true")
}
