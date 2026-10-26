import Foundation

/// Removes only provenance identifiers belonging to this exact final review.
/// Structured `AgentEvidence` remains untouched and continues to carry citations.
enum FinalContextPresentation {
    static func sanitized(_ text: String, snapshot: CallContextSnapshot) -> String {
        var result = text
        let entryIDs = Array(Set(snapshot.entries.map(\.id))).sorted { $0.count > $1.count }
        let sessionID = snapshot.sessionID.uuidString

        // Convert provider citation headers to plain quotations, but only if they
        // name identifiers from this snapshot.
        for entryID in entryIDs {
            result = replacing("Session \(sessionID), entry \(entryID):", in: result, with: "")
        }

        // Also remove exact identifiers wherever they occur in generated display
        // text. This does not scrub arbitrary UUID-like user content.
        for entryID in entryIDs {
            result = replacing(entryID, in: result, with: "")
        }
        result = replacing(sessionID, in: result, with: "")
        return result
    }

    private static func replacing(_ needle: String, in haystack: String, with replacement: String) -> String {
        haystack.replacingOccurrences(of: needle, with: replacement, options: [.caseInsensitive, .literal])
    }
}
