import Foundation

actor AgentRouter {
    private let index: WorkspaceIndex

    init(index: WorkspaceIndex) {
        self.index = index
    }

    func route(utterance: String) -> RoutingResult {
        let normalized = utterance.lowercased()
        let cues = index.search(utterance)

        let medium: TierActivity = cues.count > 1 && containsTopicShift(normalized)
            ? .working
            : .idle

        let deep: TierActivity
        if normalized.contains("investigate") || normalized.contains("look into") {
            deep = .suggested("workspace-investigation")
        } else {
            deep = .idle
        }

        return RoutingResult(cues: cues, medium: medium, deep: deep)
    }

    private func containsTopicShift(_ text: String) -> Bool {
        ["but", "also", "before we", "separately", "what about"].contains { text.contains($0) }
    }
}
