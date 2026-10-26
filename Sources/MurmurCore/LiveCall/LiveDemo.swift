import Foundation

/// A scripted sample call so the page can be tried with no audio, no network, and nothing saved.
public final class DemoSession: LiveCallControlling, @unchecked Sendable {
    struct Line { let at: Double; let speaker: String; let text: String }

    static let script: [Line] = [
        Line(at: 1.0, speaker: "them", text: "Thanks for joining, Priya. Quick agenda: the Q3 report, the vendor contract, and who is covering support next week."),
        Line(at: 6.0, speaker: "me", text: "Sounds good. I have the report mostly drafted."),
        Line(at: 10.0, speaker: "them", text: "Great. We agreed last time to ship the Q3 report on Friday, right? Finance needs it before their review."),
        Line(at: 16.0, speaker: "me", text: "Yes, Friday works. I'll send you the draft tomorrow morning."),
        Line(at: 21.0, speaker: "them", text: "Perfect. On the vendor contract, legal flagged the renewal clause. They want a thirty day exit instead of ninety."),
        Line(at: 28.0, speaker: "them", text: "Priya, can you ask the vendor whether thirty days is acceptable before Wednesday?"),
        Line(at: 34.0, speaker: "me", text: "I can. Do we know their usual position?"),
        Line(at: 38.0, speaker: "them", text: "Last renewal they pushed back on anything under sixty. So maybe offer sixty as the fallback."),
        Line(at: 45.0, speaker: "them", text: "Last thing, support cover. Marcus is out Monday through Wednesday. Can you take the queue on Tuesday?")
    ]

    static func item(_ text: String, _ entry: Int, _ quote: String, proposed: Bool = false) -> JSONValue {
        ["text": .string(text), "evidence": [["entry": JSONValue(entry), "quote": .string(quote)]], "proposed": .bool(proposed)]
    }

    static let report = item("Q3 report ships Friday (Finance needs it before their review).", 3, "ship the Q3 report on Friday")
    static let draft = item("You send the report draft tomorrow morning.", 4, "send you the draft tomorrow morning")
    static let vendor = item("You ask the vendor about a 30-day exit before Wednesday.", 6, "ask the vendor whether thirty days is acceptable")
    static let sixty = item("Offer sixty days if the vendor refuses 30.", 8, "maybe offer sixty as the fallback", proposed: true)
    static let accept30 = item("Will the vendor accept 30 days?", 5, "thirty day exit instead of ninety")
    static let tuesday = item("Can you take the support queue on Tuesday?", 9, "take the queue on Tuesday")

    static func notes(_ summary: String, decisions: [JSONValue] = [], commitments: [JSONValue] = [],
                      questions: [JSONValue] = [], findings: [JSONValue] = []) -> JSONValue {
        ["summary": .string(summary), "decisions": .array(decisions), "commitments": .array(commitments),
         "open_questions": .array(questions), "findings": .array(findings)]
    }

    static func finding(_ title: String, _ detail: String, _ entry: Int, _ quote: String) -> JSONValue {
        ["title": .string(title), "detail": .string(detail), "evidence": [["entry": JSONValue(entry), "quote": .string(quote)]]]
    }

    static let contexts: [(at: Double, value: JSONValue)] = [
        (11.0, notes("Agenda is the Q3 report, the vendor contract, and support cover. Your report is mostly drafted.")),
        (17.5, notes("Q3 report ships Friday; you send the draft tomorrow morning.",
                     decisions: [report], commitments: [draft],
                     findings: [finding("Report deadline", "Friday, driven by the Finance review.", 3, "ship the Q3 report on Friday")])),
        (29.5, notes("Report is set. Legal wants a 30-day exit on the vendor renewal; you are asked to check with the vendor by Wednesday.",
                     decisions: [report], commitments: [draft, vendor], questions: [accept30],
                     findings: [finding("Contract exit clause", "Legal wants 30 days instead of 90.", 5, "thirty day exit instead of ninety")])),
        (46.5, notes("Vendor check is yours by Wednesday, with sixty days suggested as the fallback. Marcus is out Monday to Wednesday and you are asked to cover Tuesday.",
                     decisions: [report, sixty], commitments: [draft, vendor], questions: [accept30, tuesday],
                     findings: [finding("Fallback position", "Vendor resisted anything under sixty last renewal.", 8, "pushed back on anything under sixty")]))
    ]

    static func recapStage(_ now: String, _ points: [(String, [Int])], asks: [(String, Int)] = []) -> JSONValue {
        ["now": .string(now),
         "points": .array(points.map { ["text": .string($0.0), "entries": .array($0.1.map { JSONValue($0) })] }),
         "asks_of_me": .array(asks.map { ["text": .string($0.0), "entry": JSONValue($0.1)] })]
    }

    static let recaps: [(upto: Int, value: JSONValue)] = [
        (4, recapStage("Priya has just opened with the agenda: the Q3 report, the vendor contract, and support cover.",
                       [("Agenda is the Q3 report, the vendor contract, and who covers support next week.", [1]),
                        ("You say the report is mostly drafted.", [2])])),
        (6, recapStage("The Q3 report ships Friday and you owe the draft tomorrow morning; the vendor contract is next.",
                       [("Report ships Friday; Finance needs it before their review.", [3]),
                        ("You promised the draft tomorrow morning.", [4])])),
        (8, recapStage("Legal wants a shorter exit on the vendor renewal and you are asked to check with the vendor before Wednesday.",
                       [("Report ships Friday; you send the draft tomorrow morning.", [3, 4]),
                        ("Legal wants a 30-day exit instead of 90 on the renewal.", [5]),
                        ("You are asked to ask the vendor before Wednesday, and offer sixty days as the fallback.", [6, 8])],
                       asks: [("Priya asked you to check with the vendor whether 30 days is acceptable before Wednesday.", 6)])),
        (99, recapStage("Marcus is out Monday to Wednesday and you are being asked to cover the support queue on Tuesday.",
                        [("Report ships Friday; you send the draft tomorrow morning.", [3, 4]),
                         ("Legal wants a 30-day exit on the vendor renewal; you check with the vendor by Wednesday.", [5, 6]),
                         ("If they refuse, offer sixty days; they pushed back on anything lower last time.", [8])],
                        asks: [("Can you take the support queue on Tuesday?", 9),
                               ("Check with the vendor whether 30 days is acceptable before Wednesday.", 6)]))
    ]

    static let scale = 0.8   // play a little faster than the script's clock

    public let id = "sample"
    public let isSample = true
    private let lock = NSLock()
    private let stopSignal = NSCondition()
    private var stopped = false
    private var _status = "idle"
    private var entries: [LiveEntry] = []
    private var context: JSONValue?
    private var partials: [String: String] = [:]
    private var subscribers: [ObjectIdentifier: EventQueue] = [:]
    private let speed: Double

    public init(speed: Double = 1.0) { self.speed = speed }

    public var status: String { lock.lock(); defer { lock.unlock() }; return _status }

    public func subscribe() -> EventQueue {
        let queue = EventQueue()
        lock.withLock { subscribers[ObjectIdentifier(queue)] = queue }
        return queue
    }

    public func unsubscribe(_ queue: EventQueue) {
        lock.withLock { subscribers[ObjectIdentifier(queue)] = nil }
    }

    private func emit(_ kind: String, _ data: [String: JSONValue] = [:]) {
        let queues = lock.withLock { Array(subscribers.values) }
        var event = data
        event["type"] = .string(kind)
        for queue in queues { queue.put(.object(event)) }
    }

    public func state() -> JSONValue {
        lock.lock(); defer { lock.unlock() }
        return ["id": "sample", "sample": true, "provenance": ["heard": "sample", "notes": "sample", "notes_host": ""], "status": .string(_status), "entries": .array(entries.map(\.json)),
                "partials": .object(partials.mapValues { .string($0) }), "context": context ?? .null,
                "context_error": .null, "notices": []]
    }

    public func recap(minutes: Int = 5) async throws -> JSONValue {
        let said = lock.withLock { entries }
        let stage = Self.recaps.first { said.count <= $0.upto } ?? Self.recaps[Self.recaps.count - 1]
        let latest = said.map(\.end).max() ?? 0
        let window = said.filter { $0.end >= latest - Double(minutes) * 60 }
        guard case .object(var object) = stage.value else { return .null }
        object["minutes"] = JSONValue(minutes)
        object["entries"] = JSONValue(window.count)
        object["model"] = "sample"
        object["from_s"] = .number(window.map(\.start).min() ?? 0)
        object["to_s"] = .number(latest)
        return .object(object)
    }

    public func start() throws {
        lock.withLock { _status = "listening" }
        emit("status", ["status": "listening"])
        Thread.detachNewThread { [self] in play() }
    }

    public func stop() async {
        stopSignal.withLock { stopped = true; stopSignal.broadcast() }
        lock.withLock { _status = "stopped" }
        emit("status", ["status": "stopped"])
    }

    private func wait(until seconds: Double, since start: Date) -> Bool {
        let deadline = start.addingTimeInterval(seconds * Self.scale / speed)
        stopSignal.lock(); defer { stopSignal.unlock() }
        while Date() < deadline {
            if stopped { return false }
            _ = stopSignal.wait(until: min(deadline, Date().addingTimeInterval(0.05)))
        }
        return !stopped
    }

    private enum Step { case entry(Int), context(Int) }

    private func play() {
        let start = Date()
        var steps: [(Double, Int, Step)] = Self.script.enumerated().map { ($1.at, $0, .entry($0)) }
        steps += Self.contexts.enumerated().map { ($1.at, 100 + $0, .context($0)) }
        steps.sort { ($0.0, $0.1) < ($1.0, $1.1) }
        for (at, _, step) in steps {
            switch step {
            case .entry(let index):
                let line = Self.script[index]
                let words = line.text.split(separator: " ")
                let half = words.prefix(max(3, words.count / 2)).joined(separator: " ")
                guard wait(until: at - 0.9, since: start) else { return }
                lock.withLock { partials[line.speaker] = half }
                emit("partial", ["speaker": .string(line.speaker), "text": .string(half)])
                emit("level", ["channel": .string(line.speaker), "level": 0.6])
                guard wait(until: at, since: start) else { return }
                let entry = LiveEntry(id: index + 1, speaker: line.speaker, start: at, end: at + 3, text: line.text, backend: "sample")
                lock.withLock { entries.append(entry); partials[line.speaker] = nil }
                emit("entry", ["entry": entry.json])
            case .context(let index):
                guard wait(until: at, since: start) else { return }
                guard case .object(var object) = Self.contexts[index].value else { continue }
                object["model"] = "sample"
                object["seconds"] = 0.7
                lock.withLock { object["through_entry"] = JSONValue(entries.count); context = .object(object) }
                emit("context", ["context": .object(object), "error": .null])
            }
        }
        if wait(until: (Self.script.last?.at ?? 0) + 12, since: start) { Task { await stop() } }
    }
}
