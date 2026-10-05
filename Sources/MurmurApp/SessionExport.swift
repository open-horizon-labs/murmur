import Foundation

enum SessionExportFormat: String, Sendable {
    case markdown
    case json

    var fileExtension: String { self == .markdown ? "md" : "json" }
}

enum SessionExporter {
    static func data(session: SavedSession, format: SessionExportFormat) throws -> Data {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .millisecondsSince1970
            return try encoder.encode(session)
        case .markdown:
            return Data(markdown(session).utf8)
        }
    }

    static func fileExtension(for format: SessionExportFormat) -> String {
        format.fileExtension
    }

    private static func markdown(_ session: SavedSession) -> String {
        let dateFormatter = ISO8601DateFormatter()
        var sections: [String] = [
            "# \(session.title.isEmpty ? "Untitled session" : session.title)",
            "",
            "- Created: \(date(session.createdAt, using: dateFormatter))",
            "- Workspace: \(session.workspaceName.isEmpty ? "Unknown" : session.workspaceName)",
            "- Workspace path: \(session.workspacePath ?? "Not recorded")",
            "- Updated: \(date(session.updatedAt, using: dateFormatter))",
            "",
            session.isDemo ? "_Simulated conversation_" : "_Live conversation_",
            ""
        ]

        if let original = session.postCallTranscript, session.postCallRevisionID != nil {
            appendTranscript(original, title: "## Original live transcript", to: &sections, using: dateFormatter)
            appendTranscript(session.transcript, title: "## Post-call transcript", to: &sections, using: dateFormatter)
        } else {
            appendTranscript(session.transcript, title: "## Transcript", to: &sections, using: dateFormatter)
        }

        sections.append("## Context")
        sections.append("")
        if let context = session.context {
            sections.append("_As of \(session.contextUpdatedAt.map { date($0, using: dateFormatter) } ?? "an unrecorded time") · Model: \(session.contextFindingModel ?? session.contextModel)_")
            sections.append("")
            sections.append(contentsOf: findingMarkdown(context))
            sections.append("")
        } else {
            sections.append("(No Context finding.)")
            sections.append("")
        }
        sections.append("- Context updated: \(session.contextUpdatedAt.map { date($0, using: dateFormatter) } ?? "Not recorded")")
        sections.append("")

        sections.append("## Investigations")
        sections.append("")
        if session.investigations.isEmpty {
            sections.append("(No investigations.)")
        } else {
            for investigation in session.investigations {
                sections.append("### \(investigation.question.isEmpty ? "Passage investigation" : investigation.question)")
                sections.append("")
                sections.append("- Status: \(investigation.status)")
                if let statusMessage = investigation.statusMessage { sections.append("- Status message: \(statusMessage)") }
                sections.append("")
                sections.append("Selected passage:")
                sections.append("")
                sections.append(investigation.selectionText)
                sections.append("")
                if let finding = investigation.finding {
                    sections.append(contentsOf: findingMarkdown(finding))
                    sections.append("")
                }
            }
        }
        return sections.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func findingMarkdown(_ finding: SavedFinding) -> [String] {
        var lines = [
            "### \(finding.title)",
            "",
            finding.summary,
            "",
            "Supporting evidence:"
        ]
        if finding.evidence.isEmpty {
            lines.append("- No file evidence recorded.")
        } else {
            lines.append(contentsOf: finding.evidence.map { evidence in
                let range: String
                if let start = evidence.lineStart, let end = evidence.lineEnd, start != end { range = " lines \(start)-\(end)" }
                else if let start = evidence.lineStart { range = " line \(start)" }
                else { range = "" }
                if evidence.transcriptSessionID != nil { return "- Transcript `\(evidence.transcriptEntryID ?? "")`: \(evidence.excerpt)" }
                return "- `\(evidence.path)`\(range): \(evidence.excerpt)"
            })
        }
        return lines
    }

    private static func appendTranscript(
        _ entries: [SavedTranscriptEntry], title: String, to sections: inout [String], using dateFormatter: ISO8601DateFormatter
    ) {
        sections.append(title)
        sections.append("")
        if entries.isEmpty {
            sections.append("(No transcript entries.)")
        } else {
            for entry in entries {
                sections.append("### \(date(entry.timestamp, using: dateFormatter))\(entry.isFinal ? "" : (entry.wasInterrupted == true ? " · Interrupted" : " · Unfinished"))")
                sections.append("")
                sections.append(entry.text)
                sections.append("")
            }
        }
    }

    private static func date(_ value: Date, using formatter: ISO8601DateFormatter) -> String {
        formatter.string(from: value)
    }
}
