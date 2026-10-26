import Foundation
import XCTest
@testable import MurmurCore

@MainActor
final class AppModelModelSelectionTests: XCTestCase {
    func testRefreshDoesNotChooseModelAndPreservesUnknownIDsAcrossRelaunch() async throws {
        let suite = "AppModelModelSelectionTests-\(UUID().uuidString)"
        let defaults = try makeDefaults(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let agents = ModelCatalogFake(["listed-model"])
        let firstLaunch = makeModel(defaults: defaults, agents: agents)

        XCTAssertEqual(firstLaunch.contextModel, "")
        XCTAssertEqual(firstLaunch.deepModel, "")
        await firstLaunch.refreshCodex()
        XCTAssertEqual(firstLaunch.contextModel, "")
        XCTAssertEqual(firstLaunch.deepModel, "")

        firstLaunch.contextModel = "provider/unlisted-context"
        firstLaunch.deepModel = "provider/unlisted-passage"
        await firstLaunch.refreshCodex()
        XCTAssertEqual(firstLaunch.contextModel, "provider/unlisted-context")
        XCTAssertEqual(firstLaunch.deepModel, "provider/unlisted-passage")
        XCTAssertTrue(firstLaunch.modelAvailability(firstLaunch.contextModel).contains("Not listed"))

        let relaunched = makeModel(defaults: defaults, agents: agents)
        XCTAssertEqual(relaunched.contextModel, "provider/unlisted-context")
        XCTAssertEqual(relaunched.deepModel, "provider/unlisted-passage")
    }

    func testReplacingCredentialInvalidatesCatalogButRetainsChosenModelIDs() async throws {
        let suite = "AppModelModelSelectionTests-\(UUID().uuidString)"
        let defaults = try makeDefaults(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = MemoryCredentials("old-key")
        let model = makeModel(defaults: defaults, agents: ModelCatalogFake(["listed-model"]), credentials: credentials)
        model.contextModel = "listed-model"
        model.deepModel = "provider/custom-passage"
        await model.refreshCodex()
        XCTAssertEqual(model.codexModels.map(\.model), ["listed-model"])

        XCTAssertTrue(model.saveTranscriptionAPIKey("replacement-key"))

        XCTAssertTrue(model.codexModels.isEmpty)
        XCTAssertEqual(model.contextModel, "listed-model")
        XCTAssertEqual(model.deepModel, "provider/custom-passage")
    }

    func testPassageModelWorksWithoutSelectingAContextModel() async throws {
        let suite = "AppModelModelSelectionTests-\(UUID().uuidString)"
        let defaults = try makeDefaults(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "A synthetic workspace".write(to: workspace.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let model = makeModel(defaults: defaults, agents: ModelCatalogFake(["passage-only"]))
        await model.loadWorkspace(from: workspace)
        model.deepModel = "passage-only"
        model.grantAgentConsent()
        XCTAssertFalse(model.canRunAgents)
        XCTAssertTrue(model.canInvestigate)
        model.investigate(selection: TranscriptSelection(text: "A question", entryIDs: []), question: "Investigate")
        for _ in 0..<100 where model.investigations.first?.finding == nil {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertNotNil(model.investigations.first?.finding)
        await model.stop()
    }

    func testLateCatalogFromReplacedCredentialCannotPublish() async throws {
        let suite = "AppModelModelSelectionTests-\(UUID().uuidString)"
        let defaults = try makeDefaults(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let agents = ModelCatalogFake(["old-account-model"], holdDiscovery: true)
        let model = makeModel(defaults: defaults, agents: agents, credentials: MemoryCredentials("old-key"))
        let refresh = Task { await model.refreshCodex() }
        for _ in 0..<100 {
            if await agents.hasPendingDiscovery { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(model.isLoadingCodex)
        XCTAssertTrue(model.saveTranscriptionAPIKey("new-key"))
        await agents.completeDiscovery()
        await refresh.value
        XCTAssertTrue(model.codexModels.isEmpty)
        XCTAssertFalse(model.isLoadingCodex)
    }

    func testContextInstructionsPersistRejectInvalidDraftsAndReset() async throws {
        let suite = "ContextGuidance-\(UUID().uuidString)"
        let defaults = try makeDefaults(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let agents = ModelCatalogFake([])
        let model = makeModel(defaults: defaults, agents: agents)
        XCTAssertEqual(model.contextGuidance, ContextGuidance.defaultText)
        XCTAssertTrue(model.saveContextGuidance("  Keep concise action-oriented notes.  "))
        let snapshot = CallContextSnapshot(sessionID: UUID(), revision: 1, entries: [], workspace: nil,
                                           contextGuidance: model.contextGuidance)
        XCTAssertFalse(model.saveContextGuidance("   "))
        XCTAssertFalse(model.saveContextGuidance(String(repeating: "x", count: 8_001)))
        XCTAssertEqual(model.contextGuidance, "Keep concise action-oriented notes.")
        let relaunched = makeModel(defaults: defaults, agents: agents)
        XCTAssertEqual(relaunched.contextGuidance, model.contextGuidance)
        XCTAssertTrue(model.saveContextGuidance("Focus on open questions."))
        XCTAssertEqual(snapshot.contextGuidance, "Keep concise action-oriented notes.")
        model.resetContextGuidance()
        XCTAssertEqual(model.contextGuidance, ContextGuidance.defaultText)
        XCTAssertEqual(makeModel(defaults: defaults, agents: agents).contextGuidance, ContextGuidance.defaultText)
    }

    func testContextLimitsPersistValidateResetAndSnapshot() async throws {
        let suite = "ContextLimits-\(UUID().uuidString)"
        let defaults = try makeDefaults(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let agents = ModelCatalogFake([])
        let model = makeModel(defaults: defaults, agents: agents)
        XCTAssertEqual(model.contextLimits, ContextRunLimits(lookupRounds: 30, toolCalls: 120, timeoutSeconds: 300))
        let custom = ContextRunLimits(lookupRounds: 8, toolCalls: 40, timeoutSeconds: 90)
        XCTAssertTrue(model.saveContextLimits(custom))
        let snapshot = CallContextSnapshot(sessionID: UUID(), revision: 1, entries: [], workspace: nil, contextLimits: model.contextLimits)
        for invalid in [ContextRunLimits(lookupRounds: 0), ContextRunLimits(toolCalls: 1_001), ContextRunLimits(timeoutSeconds: 29)] {
            XCTAssertFalse(model.saveContextLimits(invalid))
            XCTAssertEqual(model.contextLimits, custom)
        }
        XCTAssertEqual(makeModel(defaults: defaults, agents: agents).contextLimits, custom)
        model.resetContextLimits()
        XCTAssertEqual(snapshot.contextLimits, custom)
        XCTAssertEqual(makeModel(defaults: defaults, agents: agents).contextLimits, .defaults)
        for data in [Data("broken".utf8), try JSONEncoder().encode(ContextRunLimits(lookupRounds: 101))] {
            defaults.set(data, forKey: ContextRunLimits.preferenceKey)
            XCTAssertEqual(makeModel(defaults: defaults, agents: agents).contextLimits, .defaults)
        }
    }

    func testEffortPreferencesAreIndependentPersistedAndFrozenInSnapshots() async throws {
        let suite = "ReasoningEffort-\(UUID().uuidString)"
        let defaults = try makeDefaults(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let agents = ModelCatalogFake([])
        let model = makeModel(defaults: defaults, agents: agents)
        XCTAssertEqual(model.contextEffort, .modelDefault)
        XCTAssertEqual(model.investigationEffort, .modelDefault)
        model.contextEffort = .low
        model.investigationEffort = .high
        let snapshot = CallContextSnapshot(sessionID: UUID(), revision: 1, entries: [], workspace: nil, reasoningEffort: model.contextEffort)
        let restored = makeModel(defaults: defaults, agents: agents)
        XCTAssertEqual(restored.contextEffort, .low)
        XCTAssertEqual(restored.investigationEffort, .high)
        model.contextEffort = .modelDefault
        XCTAssertEqual(snapshot.reasoningEffort, .low)
        XCTAssertEqual(makeModel(defaults: defaults, agents: agents).contextEffort, .modelDefault)
        defaults.set("unknown-effort", forKey: ReasoningEffort.contextPreferenceKey)
        XCTAssertEqual(makeModel(defaults: defaults, agents: agents).contextEffort, .modelDefault)
        XCTAssertEqual(makeModel(defaults: defaults, agents: agents).investigationEffort, .high)
    }

    private func makeModel(
        defaults: UserDefaults,
        agents: any ConversationAgentManaging,
        credentials: any TranscriptionCredentialStore = EmptyTranscriptionCredentialStore()
    ) -> AppModel {
        AppModel(
            codexRuntime: UnusedCodexRuntime(),
            userDefaults: defaults,
            credentialStore: credentials,
            conversationAgents: agents
        )
    }

    private func makeDefaults(suite: String) throws -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw NSError(domain: "AppModelModelSelectionTests", code: 1)
        }
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

private actor ModelCatalogFake: ConversationAgentManaging {
    private let ids: [String]
    private let holdDiscovery: Bool
    private var discoveryWaiter: CheckedContinuation<Void, Never>?
    var hasPendingDiscovery: Bool { discoveryWaiter != nil }

    init(_ ids: [String], holdDiscovery: Bool = false) { self.ids = ids; self.holdDiscovery = holdDiscovery }
    func completeDiscovery() { discoveryWaiter?.resume(); discoveryWaiter = nil }

    func discover(in workspace: URL) async throws -> ([CodexModel], CodexSkillsInventory) {
        if holdDiscovery { await withCheckedContinuation { discoveryWaiter = $0 } }
        return (ids.map { CodexModel(id: $0, model: $0, displayName: $0, description: "", isDefault: false, hidden: false, defaultReasoningEffort: "") }, CodexSkillsInventory(skills: [], errors: []))
    }
    func updateContext(transcript: [TranscriptEntry], previous: AgentFinding?, workspace: URL, model: String) async throws -> AgentFinding {
        AgentFinding(id: "context", title: "Context", summary: "", evidence: [], confidence: 1, skillsUsed: [], tier: .medium)
    }
    func investigate(selection: TranscriptSelection, question: String, surrounding: [TranscriptEntry], context: AgentFinding?, workspace: URL, model: String, id: UUID) async throws -> AgentFinding {
        AgentFinding(id: id.uuidString, title: "Investigation", summary: "", evidence: [], confidence: 1, skillsUsed: [], tier: .deep)
    }
    func cancel(_ tier: AgentTier) async {}
    func cancelInvestigation(id: UUID) async {}
    func resetConversation() async {}
    func stop() async {}
}

private actor UnusedCodexRuntime: CodexAppServerRuntime {
    nonisolated let events = AsyncStream<CodexAppServerEvent> { $0.finish() }
    func start() async throws {}
    func listModels() async throws -> [CodexModel] { [] }
    func listSkills(in workspace: URL, forceReload: Bool) async throws -> CodexSkillsInventory { CodexSkillsInventory(skills: [], errors: []) }
    func startThread(_ configuration: CodexThreadConfiguration) async throws -> CodexThread { CodexThread(id: "unused", model: "unused", workspace: configuration.workspace.path) }
    func startTurn(_ configuration: CodexTurnConfiguration) async throws -> CodexTurn { CodexTurn(id: "unused", status: "completed") }
    func interrupt(threadID: String, turnID: String) async throws {}
    func stop() async {}
}

private final class MemoryCredentials: TranscriptionCredentialStore {
    private var value: String?
    init(_ value: String?) { self.value = value }
    func load() throws -> String? { value }
    func save(_ apiKey: String) throws { value = apiKey }
    func delete() throws { value = nil }
}
