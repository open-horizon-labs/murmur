import Foundation

/// Typed views of the JSON the live-call core produces, so UI code never touches `JSONValue`.

public struct LiveQuote: Equatable, Sendable, Identifiable {
    public let entry: Int
    public let quote: String
    public var id: String { "\(entry):\(quote)" }
}

/// A decision, commitment or open question. `evidence` is empty when no quote in the transcript backs it.
public struct LiveNoteItem: Equatable, Sendable, Identifiable {
    public let text: String
    public let evidence: [LiveQuote]
    public let proposed: Bool
    public var id: String { text }
    public var hasQuote: Bool { !evidence.isEmpty }

    init(_ value: JSONValue) {
        if let text = value.stringValue {
            self.init(text: text, evidence: [], proposed: false)
        } else {
            self.init(text: value["text"]?.stringValue ?? "", evidence: LiveQuote.list(value["evidence"]),
                      proposed: value["proposed"]?.boolValue ?? false)
        }
    }

    public init(text: String, evidence: [LiveQuote] = [], proposed: Bool = false) {
        self.text = text; self.evidence = evidence; self.proposed = proposed
    }
}

extension LiveQuote {
    static func list(_ value: JSONValue?) -> [LiveQuote] {
        (value?.arrayValue ?? []).compactMap { item in
            guard let entry = item["entry"]?.intValue, let quote = item["quote"]?.stringValue else { return nil }
            return LiveQuote(entry: entry, quote: quote)
        }
    }
}

public struct LiveFinding: Equatable, Sendable, Identifiable {
    public let title: String
    public let detail: String
    public let evidence: [LiveQuote]
    public var id: String { title + detail }
}

public struct LiveNotes: Equatable, Sendable {
    public var summary: String
    public var decisions: [LiveNoteItem]
    public var commitments: [LiveNoteItem]
    public var openQuestions: [LiveNoteItem]
    public var findings: [LiveFinding]
    public var model: String
    public var seconds: Double

    public init(summary: String = "", decisions: [LiveNoteItem] = [], commitments: [LiveNoteItem] = [], openQuestions: [LiveNoteItem] = [],
                findings: [LiveFinding] = [], model: String = "", seconds: Double = 0) {
        self.summary = summary; self.decisions = decisions; self.commitments = commitments; self.openQuestions = openQuestions
        self.findings = findings; self.model = model; self.seconds = seconds
    }

    public init?(_ json: JSONValue?) {
        guard let json, json.objectValue != nil else { return nil }
        func items(_ key: String) -> [LiveNoteItem] { (json[key]?.arrayValue ?? []).map(LiveNoteItem.init) }
        self.init(
            summary: json["summary"]?.stringValue ?? "",
            decisions: items("decisions"), commitments: items("commitments"), openQuestions: items("open_questions"),
            findings: (json["findings"]?.arrayValue ?? []).map {
                LiveFinding(title: $0["title"]?.stringValue ?? "", detail: $0["detail"]?.stringValue ?? "", evidence: LiveQuote.list($0["evidence"]))
            },
            model: json["model"]?.stringValue ?? "", seconds: json["seconds"]?.doubleValue ?? 0)
    }

    /// Plain text for the clipboard: the summary, then Commitments, Open questions and Decisions.
    public var clipboardText: String {
        func section(_ title: String, _ items: [LiveNoteItem]) -> String {
            items.isEmpty ? "" : "\n\(title)\n" + items.map { "- \($0.text)" }.joined(separator: "\n") + "\n"
        }
        return "\(summary)\n" + section("Commitments", commitments) + section("Open questions", openQuestions) + section("Decisions", decisions)
    }
}

public struct LiveRecapPoint: Equatable, Sendable, Identifiable {
    public let text: String
    public let entries: [Int]
    public var id: String { text }
}

public struct LiveAsk: Equatable, Sendable, Identifiable {
    public let text: String
    public let entry: Int?
    public var id: String { text }
}

public struct LiveRecap: Equatable, Sendable {
    public var now: String
    public var points: [LiveRecapPoint]
    public var asks: [LiveAsk]
    public var minutes: Int
    public var entryCount: Int
    public var fromSeconds: Double
    public var toSeconds: Double

    public init(now: String = "", points: [LiveRecapPoint] = [], asks: [LiveAsk] = [], minutes: Int = 5, entryCount: Int = 0,
                fromSeconds: Double = 0, toSeconds: Double = 0) {
        self.now = now; self.points = points; self.asks = asks; self.minutes = minutes
        self.entryCount = entryCount; self.fromSeconds = fromSeconds; self.toSeconds = toSeconds
    }

    public init?(_ json: JSONValue?) {
        guard let json, json.objectValue != nil else { return nil }
        self.init(
            now: json["now"]?.stringValue ?? "",
            points: (json["points"]?.arrayValue ?? []).map {
                LiveRecapPoint(text: $0["text"]?.stringValue ?? "", entries: ($0["entries"]?.arrayValue ?? []).compactMap(\.intValue))
            },
            asks: (json["asks_of_me"]?.arrayValue ?? []).map {
                LiveAsk(text: $0.stringValue ?? $0["text"]?.stringValue ?? "", entry: $0["entry"]?.intValue)
            },
            minutes: json["minutes"]?.intValue ?? 5, entryCount: json["entries"]?.intValue ?? 0,
            fromSeconds: json["from_s"]?.doubleValue ?? 0, toSeconds: json["to_s"]?.doubleValue ?? 0)
    }
}

public enum ReadinessState: String, Sendable { case ok, warn, fail }

public struct ReadinessRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let state: ReadinessState
    public let detail: String
    public let fix: String

    public init(id: String, label: String, state: ReadinessState, detail: String, fix: String = "") {
        self.id = id; self.label = label; self.state = state; self.detail = detail; self.fix = fix
    }

    public init?(_ json: JSONValue) {
        guard let id = json["id"]?.stringValue, let label = json["label"]?.stringValue else { return nil }
        self.init(id: id, label: label, state: ReadinessState(rawValue: json["state"]?.stringValue ?? "") ?? .warn,
                  detail: json["detail"]?.stringValue ?? "", fix: json["fix"]?.stringValue ?? "")
    }

    public var json: JSONValue {
        ["id": .string(id), "label": .string(label), "state": .string(state.rawValue), "detail": .string(detail), "fix": .string(fix)]
    }
}

public extension LiveEntry {
    /// "mm:ss" on the call clock.
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
