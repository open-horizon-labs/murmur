import Foundation
import XCTest
@testable import MurmurApp

final class AgentCoordinatorTests: XCTestCase {
    func testContextKeepsPriorSnapshotAndUsesFreshEphemeralThread() async throws {
        let runtime = CoordinatorFakeRuntime()
        let coordinator = AgentCoordinator(runtime: runtime)
        let workspace = FileManager.default.temporaryDirectory
        let previous = AgentFinding(
            id: "prior",
            title: "Existing understanding",
            summary: "The service retries three times before the recent correction.",
            evidence: [],
            confidence: 0.8,
            skillsUsed: [],
            tier: .medium
        )
        let transcript = [TranscriptEntry(
            id: "entry-1",
            timestamp: Date(),
            text: "Correction: the retry limit is four.",
            isFinal: true
        )]

        let finding = try await coordinator.updateContext(
            transcript: transcript,
            previous: previous,
            workspace: workspace,
            model: "fake-context"
        )
        let turns = await runtime.turnConfigurations
        let threads = await runtime.threadConfigurations

        XCTAssertEqual(finding.title, "Retry policy")
        XCTAssertTrue(turns[0].prompt.contains("The service retries three times"))
        XCTAssertTrue(turns[0].prompt.contains("Correction: the retry limit is four."))
        XCTAssertTrue(turns[0].prompt.contains("Make corrections explicit"))
        XCTAssertEqual(threads.count, 1)
        XCTAssertTrue(threads[0].ephemeral)
        XCTAssertEqual(threads[0].model, "fake-context")
        await coordinator.stop()
    }

    func testInvestigationKeepsQuestionSeparateFromExactSelectedPassage() async throws {
        let runtime = CoordinatorFakeRuntime()
        let coordinator = AgentCoordinator(runtime: runtime)
        let passage = "The user said: \"retry after the third failure\"."
        let question = "Does the implementation retry three or four times?"
        let investigationID = UUID()

        _ = try await coordinator.investigate(
            selection: TranscriptSelection(text: passage, entryIDs: ["entry-2"]),
            question: question,
            surrounding: [TranscriptEntry(id: "entry-1", timestamp: Date(), text: "We discussed retries.", isFinal: true)],
            context: nil,
            workspace: FileManager.default.temporaryDirectory,
            model: "fake-deep",
            id: investigationID
        )

        let turns = await runtime.turnConfigurations
        let threads = await runtime.threadConfigurations
        XCTAssertTrue(turns[0].prompt.contains("User question, limited to 2,000 characters:\n\(question)"))
        XCTAssertTrue(turns[0].prompt.contains("Selected passage, limited to 12,000 characters:\n\(passage)"))
        XCTAssertTrue(turns[0].prompt.contains("Selected transcript entry IDs: entry-2"))
        XCTAssertEqual(threads.count, 1)
        XCTAssertTrue(threads[0].ephemeral)
        XCTAssertEqual(threads[0].model, "fake-deep")
        await coordinator.stop()
    }

    func testEachOperationStartsAnIndependentThread() async throws {
        let runtime = CoordinatorFakeRuntime()
        let coordinator = AgentCoordinator(runtime: runtime)
        let workspace = FileManager.default.temporaryDirectory

        _ = try await coordinator.updateContext(transcript: [], previous: nil, workspace: workspace, model: "fake-context")
        _ = try await coordinator.investigate(
            selection: TranscriptSelection(text: "Look here", entryIDs: ["one"]),
            question: "What does this mean?",
            surrounding: [],
            context: nil,
            workspace: workspace,
            model: "fake-deep",
            id: UUID()
        )

        let threads = await runtime.threadConfigurations
        XCTAssertEqual(threads.count, 2)
        XCTAssertNotEqual(threads[0].model, threads[1].model)
        XCTAssertTrue(threads.allSatisfy(\.ephemeral))
        await coordinator.stop()
    }

    func testCancelResumesAnUnfinishedTurnWithoutServerCompletion() async throws {
        let runtime = CoordinatorFakeRuntime(completesTurnsImmediately: false)
        let coordinator = AgentCoordinator(runtime: runtime)
        let task = Task {
            try await coordinator.updateContext(
                transcript: [], previous: nil,
                workspace: FileManager.default.temporaryDirectory,
                model: "fake-context"
            )
        }
        await runtime.waitForTurnCount(1)

        await coordinator.cancel(.medium)
        do {
            _ = try await task.value
            XCTFail("Expected cancellation to release the pending turn")
        } catch is CancellationError {
            // Expected; the runtime intentionally never completed this turn.
        }
        await coordinator.stop()
    }

    func testCoordinatorDeadlineReleasesAnUnfinishedTurn() async throws {
        let runtime = CoordinatorFakeRuntime(completesTurnsImmediately: false)
        let coordinator = AgentCoordinator(runtime: runtime, contextTimeout: .milliseconds(30))
        do {
            _ = try await coordinator.updateContext(
                transcript: [], previous: nil,
                workspace: FileManager.default.temporaryDirectory,
                model: "fake-context"
            )
            XCTFail("Expected the context deadline to expire")
        } catch AgentCoordinatorError.timedOut {
            // Expected; no completion event is emitted by the fake.
        }
        await coordinator.stop()
    }

    func testResetIgnoresLateEventsFromThePreviousConversation() async throws {
        let runtime = CoordinatorFakeRuntime(completesTurnsImmediately: false)
        let coordinator = AgentCoordinator(runtime: runtime)
        let workspace = FileManager.default.temporaryDirectory
        let first = Task {
            try await coordinator.updateContext(transcript: [], previous: nil, workspace: workspace, model: "fake-context")
        }
        await runtime.waitForTurnCount(1)
        await coordinator.resetConversation()
        do {
            _ = try await first.value
            XCTFail("Expected reset to cancel the previous conversation")
        } catch is CancellationError {
            // Expected.
        }

        let second = Task {
            try await coordinator.updateContext(transcript: [], previous: nil, workspace: workspace, model: "fake-context")
        }
        await runtime.waitForTurnCount(2)
        await runtime.completeTurn(at: 0)
        await runtime.completeTurn(at: 1)
        let result = try await second.value
        XCTAssertEqual(result.title, "Retry policy")
        await coordinator.stop()
    }

    func testLiveDiscoveryHandshakeWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["MURMUR_LIVE_CODEX_TEST"] == "1" else {
            throw XCTSkip("Set MURMUR_LIVE_CODEX_TEST=1 to probe the installed Codex App Server.")
        }

        let runtime = try CodexAppServerClient()
        try await runtime.start()
        let models = try await runtime.listModels()
        let skills = try await runtime.listSkills(
            in: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            forceReload: false
        )
        await runtime.stop()

        XCTAssertFalse(models.isEmpty)
        XCTAssertFalse(skills.skills.isEmpty)
    }

    func testLiveContextAndInvestigationWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["MURMUR_LIVE_CODEX_TURN_TEST"] == "1",
              let selectedModel = ProcessInfo.processInfo.environment["MURMUR_LIVE_API_MODEL"], !selectedModel.isEmpty else {
            throw XCTSkip("Set MURMUR_LIVE_CODEX_TURN_TEST=1 and MURMUR_LIVE_API_MODEL to run bounded Context and investigation turns.")
        }

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-luna-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try """
        enum RetryPolicy {
            static let maximumAttempts = 4
            static let baseDelayMilliseconds = 250
        }
        """.write(to: workspace.appendingPathComponent("RetryPolicy.swift"), atomically: true, encoding: .utf8)

        let runtime = try CodexAppServerClient()
        let coordinator = AgentCoordinator(runtime: runtime)
        do {
            let (models, _) = try await coordinator.discover(in: workspace)
            XCTAssertTrue(models.contains { $0.model == selectedModel })

            let context = try await coordinator.updateContext(
                transcript: [TranscriptEntry(id: "spoken-1", timestamp: Date(), text: "We are checking the retry limit.", isFinal: true)],
                previous: nil,
                workspace: workspace,
                model: selectedModel
            )
            let result = try await coordinator.investigate(
                selection: TranscriptSelection(text: "The code should retry after failures.", entryIDs: ["spoken-1"]),
                question: "What retry limit is implemented?",
                surrounding: [],
                context: context,
                workspace: workspace,
                model: selectedModel,
                id: UUID()
            )

            XCTAssertFalse(context.summary.isEmpty)
            XCTAssertFalse(result.summary.isEmpty)
            XCTAssertTrue(result.evidence.contains { $0.path.contains("RetryPolicy.swift") && $0.excerpt.contains("maximumAttempts") })
            XCTAssertEqual(context.tier, .medium)
            XCTAssertEqual(result.tier, .deep)
        } catch {
            await coordinator.stop()
            throw error
        }
        await coordinator.stop()
    }
}

private actor CoordinatorFakeRuntime: CodexAppServerRuntime {
    nonisolated let events: AsyncStream<CodexAppServerEvent>
    private let continuation: AsyncStream<CodexAppServerEvent>.Continuation
    private(set) var threadConfigurations: [CodexThreadConfiguration] = []
    private(set) var turnConfigurations: [CodexTurnConfiguration] = []
    private(set) var startedTurns: [(CodexTurnConfiguration, CodexTurn)] = []
    private var threadNumber = 0
    private var turnNumber = 0
    private let completesTurnsImmediately: Bool
    private var turnCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(completesTurnsImmediately: Bool = true) {
        self.completesTurnsImmediately = completesTurnsImmediately
        let pair = AsyncStream.makeStream(of: CodexAppServerEvent.self)
        events = pair.stream
        continuation = pair.continuation
    }

    func start() async throws {}

    func listModels() async throws -> [CodexModel] {
        [
            CodexModel(id: "context", model: "fake-context", displayName: "Context", description: "", isDefault: true, hidden: false, defaultReasoningEffort: "low"),
            CodexModel(id: "deep", model: "fake-deep", displayName: "Deep", description: "", isDefault: false, hidden: false, defaultReasoningEffort: "high")
        ]
    }

    func listSkills(in workspace: URL, forceReload: Bool) async throws -> CodexSkillsInventory {
        CodexSkillsInventory(skills: [CodexSkill(
            workspace: workspace.path,
            name: "code-search",
            description: "Search code",
            enabled: true,
            path: workspace.appendingPathComponent("SKILL.md").path,
            scope: "repo"
        )], errors: [])
    }

    func startThread(_ configuration: CodexThreadConfiguration) async throws -> CodexThread {
        threadNumber += 1
        threadConfigurations.append(configuration)
        return CodexThread(id: "thread-\(threadNumber)", model: configuration.model ?? "fake-context", workspace: configuration.workspace.path)
    }

    func startTurn(_ configuration: CodexTurnConfiguration) async throws -> CodexTurn {
        turnNumber += 1
        turnConfigurations.append(configuration)
        let turn = CodexTurn(id: "turn-\(turnNumber)", status: "inProgress")
        let output = """
        I found the relevant implementation and checked its constants.
        {"title":"Retry policy","summary":"Retries use capped exponential backoff.","evidence":[{"path":"Sources/Retry.swift","lineStart":42,"lineEnd":48,"excerpt":"let delay = min(cap, base * attempt)"}],"confidence":0.94,"skillsUsed":["code-search"]}
        """
        startedTurns.append((configuration, turn))
        resumeTurnCountWaiters()
        if completesTurnsImmediately {
            continuation.yield(.agentMessageDelta(threadID: configuration.threadID, turnID: turn.id, delta: output))
            continuation.yield(.turnCompleted(threadID: configuration.threadID, turnID: turn.id, status: "completed"))
        }
        return turn
    }

    func waitForTurnCount(_ count: Int) async {
        if startedTurns.count >= count { return }
        await withCheckedContinuation { continuation in
            turnCountWaiters.append((count, continuation))
        }
    }

    func completeTurn(at index: Int) {
        let (configuration, turn) = startedTurns[index]
        let output = """
        {"title":"Retry policy","summary":"Retries use capped exponential backoff.","evidence":[],"confidence":0.94,"skillsUsed":[]}
        """
        continuation.yield(.agentMessageDelta(threadID: configuration.threadID, turnID: turn.id, delta: output))
        continuation.yield(.turnCompleted(threadID: configuration.threadID, turnID: turn.id, status: "completed"))
    }

    private func resumeTurnCountWaiters() {
        let ready = turnCountWaiters.filter { startedTurns.count >= $0.0 }
        turnCountWaiters.removeAll { startedTurns.count >= $0.0 }
        for (_, continuation) in ready { continuation.resume() }
    }

    func interrupt(threadID: String, turnID: String) async throws {}
    func stop() async { continuation.finish() }
}
