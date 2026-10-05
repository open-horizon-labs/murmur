import Foundation

/// User-editable writing guidance; source access and evidence rules remain fixed.
enum ContextGuidance {
    static let preferenceKey = "contextGuidance"
    static let maximumLength = 8_000
    static let defaultText = """
    Write practical personal call notes centered on the discussion, decisions, useful context, and next steps.

    Use clear, natural language. Do not prefix each point with Spoken, File evidence, or Inference. Treat ordinary statements as the conversation's working context, without repeatedly calling them claims, self-reported, or unverified. Avoid unsolicited credibility assessments, performance evaluations, and generic warnings that no files corroborate what was said.

    Distinguish proposals, estimates, and agreed commitments in natural language. Preserve corrections and conditions. Flag uncertainty when an ambiguity, contradiction, inference, or missing detail materially changes understanding or a next step. Attribute points when useful. Do not carry forward an evaluative tone or stale caveats from earlier notes.

    During the call, keep updates concise, using Understanding, Decisions & next steps, and Open questions as useful. Use fewer words when little has changed.

    After the call, use Summary, Actions, and Open questions as useful. Include Unclear passages only for material ambiguities and Relevant files only when relevant files were actually inspected. Omit empty sections.
    """

    static func validated(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= maximumLength ? trimmed : nil
    }

    static func load(from defaults: UserDefaults) -> String {
        defaults.string(forKey: preferenceKey).flatMap(validated) ?? defaultText
    }
}
