import Foundation

/// An immutable, call-scoped view of one settled transcript and optional workspace.
struct CallContextSnapshot: Sendable {
    let sessionID: UUID
    let revision: Int
    let entries: [TranscriptEntry]
    let workspace: URL?
    let isFinalReview: Bool
    let contextGuidance: String
    let contextLimits: ContextRunLimits
    let reasoningEffort: ReasoningEffort

    init(sessionID: UUID, revision: Int, entries: [TranscriptEntry], workspace: URL?, isFinalReview: Bool = false, contextGuidance: String = ContextGuidance.defaultText, contextLimits: ContextRunLimits = .defaults, reasoningEffort: ReasoningEffort = .modelDefault) {
        self.sessionID = sessionID
        self.revision = revision
        self.entries = entries
        self.workspace = workspace
        self.isFinalReview = isFinalReview
        self.contextGuidance = contextGuidance
        self.contextLimits = contextLimits.validated
        self.reasoningEffort = reasoningEffort
    }
}

struct TranscriptEntry: Identifiable, Equatable, Sendable {
    let id: String
    let timestamp: Date
    var text: String
    var isFinal: Bool
    var wasInterrupted: Bool? = nil
    var isSystemNotice: Bool { id.hasPrefix("system:") }
}

struct TranscriptSelection: Equatable, Sendable {
    let text: String
    let entryIDs: [String]
}

struct PassageInvestigation: Identifiable, Equatable, Sendable {
    let id: UUID
    let selection: TranscriptSelection
    let question: String
    var activity: TierActivity
    var finding: AgentFinding?
}

protocol ConversationAgentManaging: Sendable {
    func discover(in workspace: URL) async throws -> ([CodexModel], CodexSkillsInventory)
    func updateContext(
        transcript: [TranscriptEntry],
        previous: AgentFinding?,
        workspace: URL,
        model: String
    ) async throws -> AgentFinding
    func investigate(
        selection: TranscriptSelection,
        question: String,
        surrounding: [TranscriptEntry],
        context: AgentFinding?,
        workspace: URL,
        model: String,
        id: UUID
    ) async throws -> AgentFinding
    func updateContext(snapshot: CallContextSnapshot, previous: AgentFinding?, model: String) async throws -> AgentFinding
    func investigate(selection: TranscriptSelection, question: String, snapshot: CallContextSnapshot, context: AgentFinding?, model: String, id: UUID) async throws -> AgentFinding
    func cancel(_ tier: AgentTier) async
    func cancelInvestigation(id: UUID) async
    func resetConversation() async
    func stop() async
}

enum SnapshotAgentError: LocalizedError {
    case unsupportedWithoutWorkspace

    var errorDescription: String? {
        "This conversation agent does not support call-scoped transcript analysis without a workspace."
    }
}

extension ConversationAgentManaging {
    func updateContext(snapshot: CallContextSnapshot, previous: AgentFinding?, model: String) async throws -> AgentFinding {
        guard let workspace = snapshot.workspace else { throw SnapshotAgentError.unsupportedWithoutWorkspace }
        return try await updateContext(transcript: snapshot.entries, previous: previous, workspace: workspace, model: model)
    }

    func investigate(selection: TranscriptSelection, question: String, snapshot: CallContextSnapshot, context: AgentFinding?, model: String, id: UUID) async throws -> AgentFinding {
        guard let workspace = snapshot.workspace else { throw SnapshotAgentError.unsupportedWithoutWorkspace }
        let selected = Set(selection.entryIDs)
        let entries = snapshot.entries
        let indices = entries.indices.filter { selected.contains(entries[$0].id) }
        let surrounding: [TranscriptEntry]
        if let first = indices.min(), let last = indices.max() {
            surrounding = Array(entries[max(0, first - 3)...min(entries.count - 1, last + 3)])
        } else {
            surrounding = []
        }
        return try await investigate(selection: selection, question: question, surrounding: surrounding, context: context, workspace: workspace, model: model, id: id)
    }
}
