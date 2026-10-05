import Foundation

/// Read-only bounded navigation over the exact transcript snapshot attached to a call.
actor CallTranscriptTools {
    private let snapshot: CallContextSnapshot
    private var inspectedTextsByEntryID: [String: [String]] = [:]
    private var fullyInspectedEntryOffsets: Set<Int> = []
    private let maximumWindowEntries = 24
    private let maximumResultBytes = 24_000

    init(snapshot: CallContextSnapshot) { self.snapshot = snapshot }

    nonisolated static var definitions: [JSONValue] {
        [
            schema("read_call_transcript", "Read a bounded window of the full call transcript. Offset is zero-based and entries are in captured order.", [
                "offset": .object(["type": .string("integer"), "minimum": .number(0)]),
                "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(24)])
            ], ["offset", "limit"]),
            schema("search_call_transcript", "Search the full call transcript for a phrase or term and return bounded matching entries with stable IDs.", [
                "term": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(200)]),
                "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(24)])
            ], ["term", "limit"])
        ]
    }

    func execute(name: String, arguments: String) throws -> String {
        guard let data = arguments.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ToolError.invalidArguments }
        let selected: [(Int, TranscriptEntry, String?)]
        switch name {
        case "read_call_transcript":
            guard let offset = object["offset"] as? Int, let limit = object["limit"] as? Int,
                  offset >= 0, (1...maximumWindowEntries).contains(limit) else { throw ToolError.invalidArguments }
            selected = Array(snapshot.entries.enumerated().dropFirst(offset).prefix(limit).map { ($0.offset, $0.element, nil) })
        case "search_call_transcript":
            guard let term = object["term"] as? String, !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  term.utf8.count <= 200, let limit = object["limit"] as? Int,
                  (1...maximumWindowEntries).contains(limit) else { throw ToolError.invalidArguments }
            selected = Array(snapshot.entries.enumerated().filter { $0.element.text.localizedCaseInsensitiveContains(term) }.prefix(limit).map { ($0.offset, $0.element, Self.searchExcerpt($0.element.text, term: term)) })
        default: throw ToolError.unknownTool
        }
        let offset = name == "read_call_transcript" ? (object["offset"] as? Int ?? 0) : nil
        var output = "session_id=\(snapshot.sessionID.uuidString) revision=\(snapshot.revision) total_entries=\(snapshot.entries.count)\n"
        var returnedCount = 0
        for (entryOffset, entry, matchExcerpt) in selected {
            let state = settledEligible(entry) ? "FINAL_SPEECH" : entry.isSystemNotice ? "SYSTEM_NOTICE_NOT_SPEECH" : entry.wasInterrupted == true ? "INTERRUPTED_NOT_SETTLED" : entry.isFinal ? "FINAL_NOT_SETTLED" : "PROVISIONAL_NOT_SETTLED"
            let shownText = matchExcerpt ?? Self.utf8Prefix(entry.text, maxBytes: 4_000)
            let id = entry.id.utf8.count <= 512 ? entry.id : "(omitted: entry ID over 512 bytes)"
            let line = "[offset=\(entryOffset) \(state) id=\(id)] \(shownText)\(shownText.utf8.count < entry.text.utf8.count ? " [entry text truncated]" : "")\n"
            guard output.utf8.count + line.utf8.count <= maximumResultBytes else { break }
            output += line
            returnedCount += 1
            if entry.id.utf8.count <= 512 {
                inspectedTextsByEntryID[entry.id, default: []].append(shownText)
                if name == "read_call_transcript", settledEligible(entry), shownText == entry.text {
                    fullyInspectedEntryOffsets.insert(entryOffset)
                }
            }
        }
        if let offset {
            output = "session_id=\(snapshot.sessionID.uuidString) revision=\(snapshot.revision) total_entries=\(snapshot.entries.count) offset=\(offset) next_offset=\(offset + returnedCount) has_more=\(offset + returnedCount < snapshot.entries.count)\n" + output.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
        }
        return output
    }

    func validatedEvidence(_ evidence: [AgentEvidence]) -> [AgentEvidence] {
        evidence.compactMap { item in
            guard let sessionID = item.transcriptSessionID,
                  sessionID.caseInsensitiveCompare(snapshot.sessionID.uuidString) == .orderedSame,
                  let entryID = item.transcriptEntryID,
                  let inspectedTexts = inspectedTextsByEntryID[entryID],
                  let entry = snapshot.entries.first(where: { $0.id == entryID }),
                  snapshot.entries.filter({ $0.id == entryID }).count == 1,
                  settledEligible(entry), !item.excerpt.isEmpty,
                  inspectedTexts.contains(where: { $0.contains(item.excerpt) }) else { return nil }
            return AgentEvidence(path: "", lineStart: nil, lineEnd: nil, excerpt: item.excerpt,
                                 transcriptSessionID: snapshot.sessionID.uuidString, transcriptEntryID: entryID)
        }
    }

    func remainingFinalReadCount() -> Int {
        snapshot.entries.enumerated().filter { settledEligible($0.element) && !fullyInspectedEntryOffsets.contains($0.offset) }.count
    }

    private func settledEligible(_ entry: TranscriptEntry) -> Bool {
        entry.isFinal && entry.wasInterrupted != true && !entry.isSystemNotice
    }

    private nonisolated static func utf8Prefix(_ text: String, maxBytes: Int) -> String {
        var scalars = String.UnicodeScalarView()
        var count = 0
        for scalar in text.unicodeScalars {
            let width = scalar.utf8.count
            guard count + width <= maxBytes else { break }
            scalars.append(scalar)
            count += width
        }
        return String(scalars)
    }

    private nonisolated static func searchExcerpt(_ text: String, term: String) -> String {
        guard let match = text.range(of: term, options: [.caseInsensitive]) else { return utf8Prefix(text, maxBytes: 4_000) }
        let scalars = text.unicodeScalars
        let before = scalars.distance(from: scalars.startIndex, to: match.lowerBound)
        let after = scalars.distance(from: match.upperBound, to: scalars.endIndex)
        let start = scalars.index(match.lowerBound, offsetBy: -min(400, before), limitedBy: scalars.startIndex) ?? scalars.startIndex
        let end = scalars.index(match.upperBound, offsetBy: min(400, after), limitedBy: scalars.endIndex) ?? scalars.endIndex
        return String(text[start..<end])
    }

    private static func schema(_ name: String, _ description: String, _ properties: [String: JSONValue], _ required: [String]) -> JSONValue {
        .object(["type": .string("function"), "name": .string(name), "description": .string(description),
                 "parameters": .object(["type": .string("object"), "properties": .object(properties),
                                         "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)]), "strict": .bool(true)])
    }

    enum ToolError: Error { case invalidArguments, unknownTool }
}
