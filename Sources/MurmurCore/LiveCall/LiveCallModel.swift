import Foundation
import Observation

/// The state behind the live-call screens. No UI framework: the SwiftUI views (macOS) read it, and the logic is
/// tested on Linux. It mirrors the behaviour of call-memory's page.html.
@MainActor
@Observable
public final class LiveCallModel {
    public enum Phase: String, Sendable { case idle, listening, stopping, stopped }

    public typealias MakeCall = @MainActor () throws -> any LiveCallControlling
    public typealias ReadinessProvider = @MainActor () async -> [ReadinessRow]

    // Call
    public private(set) var phase: Phase = .idle
    public private(set) var isSample = false
    public private(set) var entries: [LiveEntry] = []
    public private(set) var partials: [String: String] = [:]
    public private(set) var notes: LiveNotes?
    public private(set) var provenance: [String: String] = [:]
    public private(set) var levels: [String: Double] = [:]
    public private(set) var elapsedSeconds = 0
    public private(set) var notices: [String] = []
    public private(set) var notesError: String?
    public private(set) var startError: String?

    // Catch-up
    public var recapMinutes = 5
    public private(set) var recap: LiveRecap?
    public private(set) var recapError: String?
    public private(set) var isSummarizing = false
    /// Highest entry id the shown recap already covers (0 when there is no recap).
    public private(set) var recapUpToEntryID = 0

    // Readiness (idle screen)
    public private(set) var readiness: [ReadinessRow] = []
    public private(set) var canStart = true
    public private(set) var hasSeenCall: Bool

    // Transcript navigation
    public var pinnedToLatest = true
    public private(set) var highlightedEntryID: Int?
    public private(set) var scrollRequest: ScrollRequest?
    public private(set) var copied = false

    public struct ScrollRequest: Equatable, Sendable { public let entryID: Int; public let token: Int }

    private let makeSession: MakeCall
    private let makeDemo: MakeCall
    private let readinessProvider: ReadinessProvider
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private var session: (any LiveCallControlling)?
    private var consumer: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var highlightClear: Task<Void, Never>?
    private var startedAt: Date?
    private var levelStamps: [String: Date] = [:]
    private var scrollToken = 0
    private static let seenKey = "liveCall.hasSeenCall"
    static let levelHold: TimeInterval = 0.45
    public static let idleLevel = 0.04

    public init(
        makeSession: @escaping MakeCall,
        makeDemo: @escaping MakeCall = { DemoSession() },
        readiness: @escaping ReadinessProvider = { [] },
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.makeSession = makeSession
        self.makeDemo = makeDemo
        self.readinessProvider = readiness
        self.defaults = defaults
        self.now = now
        hasSeenCall = defaults.bool(forKey: Self.seenKey)
    }

    // MARK: derived text

    public var isCallScreen: Bool { phase != .idle }
    public var isEnded: Bool { phase == .stopped }

    public var statusText: String {
        switch phase {
        case .idle: "Not listening"
        case .listening: isSample ? "Sample call" : "Listening"
        case .stopping: "Finishing…"
        case .stopped: isSample ? "Sample ended" : "Saved · " + LiveEntry.clock(Double(elapsedSeconds))
        }
    }

    public var elapsedText: String { LiveEntry.clock(Double(elapsedSeconds)) }

    public var primaryTitle: String {
        switch phase {
        case .idle: "Start call"
        case .listening: "Stop call"
        case .stopping: "Finishing…"
        case .stopped: "New call"
        }
    }

    public var primaryEnabled: Bool { phase == .stopping ? false : (phase == .idle ? canStart : true) }

    public var provenanceText: String {
        if isSample { return "Sample call · nothing is recorded or sent" }
        guard let heard = provenance["heard"], !heard.isEmpty else { return "" }
        let host = provenance["notes_host"] ?? ""
        return "Heard by \(heard) · Notes by \(provenance["notes"] ?? "")" + (host.isEmpty ? "" : ", call text goes to \(host)")
    }

    public var banner: String? {
        if let startError { return startError }
        if let notesError { return "Notes did not update: \(notesError) Showing the last good notes." }
        return notices.last
    }

    public var canCatchUp: Bool { !entries.isEmpty && phase != .stopped && phase != .idle && !isSummarizing }

    /// New transcript lines since the shown recap was made (0 when none or no recap).
    public var newLinesSinceRecap: Int {
        guard recapUpToEntryID > 0 else { return 0 }
        return entries.filter { $0.id > recapUpToEntryID }.count
    }

    public var isRecapStale: Bool { newLinesSinceRecap > 0 }

    public var recapAsOfText: String? {
        guard let recap else { return nil }
        return "As of \(LiveEntry.clock(recap.toSeconds)) · covers \(LiveEntry.clock(recap.fromSeconds))–\(LiveEntry.clock(recap.toSeconds))"
    }

    public var staleHint: String? {
        let count = newLinesSinceRecap
        guard count > 0 else { return nil }
        return "\(count) new line\(count > 1 ? "s" : ""). Press Catch me up."
    }

    public var savedMessage: String? {
        guard isEnded else { return nil }
        return isSample ? "Sample finished. Nothing was recorded."
            : "Saved on this computer. Audio goes to your archive on the next sync; the speaker-labelled transcript follows."
    }

    /// First 7 words of an entry in quotes, for chips that carry no quote of their own.
    public func snippet(forEntry id: Int) -> String {
        guard let entry = entries.first(where: { $0.id == id }) else { return String(id) }
        let words = entry.text.split(whereSeparator: { $0.isWhitespace })
        return "“" + words.prefix(7).joined(separator: " ") + (words.count > 7 ? "…" : "") + "”"
    }

    public var notesClipboardText: String {
        if let notes { return notes.clipboardText }
        return entries.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    // MARK: readiness

    public func refreshReadiness() async {
        let rows = await readinessProvider()
        readiness = rows
        canStart = !rows.contains { $0.state == .fail }
    }

    // MARK: lifecycle

    public func startCall() { begin(makeSession, sample: false) }
    public func startSample() { begin(makeDemo, sample: true) }

    private func begin(_ make: MakeCall, sample: Bool) {
        guard phase == .idle || phase == .stopped else { return }
        if phase == .stopped { newCall() }
        startError = nil
        let next: any LiveCallControlling
        do { next = try make() } catch {
            startError = "Could not start: \(error.localizedDescription)"
            return
        }
        resetCallState()
        isSample = sample
        session = next
        let queue = next.subscribe()
        do { try next.start() } catch {
            next.unsubscribe(queue)
            session = nil
            startError = "Could not start: \(error.localizedDescription)"
            return
        }
        defaults.set(true, forKey: Self.seenKey)
        hasSeenCall = true
        startedAt = now()
        phase = .listening
        provenance = (next.state()["provenance"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
        consume(queue, from: next)
        startTicker()
    }

    public func stopCall() async {
        guard let session, phase == .listening else { return }
        phase = .stopping
        await session.stop()
        await consumer?.value
        tick()
    }

    /// Back to the idle screen (the page's "New call").
    public func newCall() {
        consumer?.cancel(); ticker?.cancel(); highlightClear?.cancel()
        if let session, phase == .listening { Task { await session.stop() } }
        session = nil
        resetCallState()
        phase = .idle
    }

    /// The primary header button: start, stop or begin again depending on the phase.
    public func primaryAction() async {
        switch phase {
        case .idle: startCall()
        case .listening: await stopCall()
        case .stopped: newCall(); await refreshReadiness()
        case .stopping: break
        }
    }

    /// For capture backends that fail after the call has started (permission denied, device gone).
    public func report(_ message: String) {
        if !notices.contains(message) { notices.append(message) }
    }

    private func resetCallState() {
        entries = []; partials = [:]; notes = nil; provenance = [:]; levels = [:]; levelStamps = [:]
        elapsedSeconds = 0; notices = []; notesError = nil
        recap = nil; recapError = nil; isSummarizing = false; recapUpToEntryID = 0
        pinnedToLatest = true; highlightedEntryID = nil; scrollRequest = nil; copied = false
        isSample = false; startedAt = nil
    }

    // MARK: events

    private func consume(_ queue: EventQueue, from session: any LiveCallControlling) {
        consumer?.cancel()
        consumer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let event = await Self.next(queue)
                guard let self else { return }
                if let event, self.apply(event) { break }
            }
            session.unsubscribe(queue)
        }
    }

    nonisolated private static func next(_ queue: EventQueue) async -> JSONValue? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: queue.get(timeout: 0.25)) }
        }
    }

    /// Apply one session event. Returns true when the call has ended.
    @discardableResult
    public func apply(_ event: JSONValue) -> Bool {
        switch event["type"]?.stringValue {
        case "entry":
            if let json = event["entry"], let id = json["id"]?.intValue {
                let entry = LiveEntry(id: id, speaker: json["speaker"]?.stringValue ?? "", start: json["start"]?.doubleValue ?? 0,
                                      end: json["end"]?.doubleValue ?? 0, text: json["text"]?.stringValue ?? "",
                                      backend: json["backend"]?.stringValue ?? "")
                partials[entry.speaker] = nil
                let at = entries.firstIndex { $0.start > entry.start } ?? entries.count
                entries.insert(entry, at: at)
            }
        case "partial":
            if let speaker = event["speaker"]?.stringValue { partials[speaker] = event["text"]?.stringValue ?? "" }
        case "context":
            if let parsed = LiveNotes(event["context"]) { notes = parsed }
            notesError = event["error"]?.stringValue
        case "notice":
            if let text = event["text"]?.stringValue { report(text) }
        case "level":
            if let channel = event["channel"]?.stringValue, let level = event["level"]?.doubleValue {
                levels[channel] = max(Self.idleLevel, min(1, level))
                levelStamps[channel] = now()
            }
        case "status":
            return applyStatus(event["status"]?.stringValue ?? "")
        default:
            break
        }
        return false
    }

    private func applyStatus(_ status: String) -> Bool {
        switch status {
        case "listening": phase = .listening
        case "stopping": phase = .stopping
        case "stopped":
            tick()
            phase = .stopped
            partials = [:]
            levels = [:]; levelStamps = [:]
            ticker?.cancel()
            return true
        default: break
        }
        return false
    }

    // MARK: clock and level decay

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    /// Advance elapsed time and let quiet level meters fall back to idle. Called by the ticker; tests call it directly.
    public func tick() {
        if let startedAt, phase == .listening || phase == .stopping {
            let seconds = max(0, Int(now().timeIntervalSince(startedAt)))
            if seconds != elapsedSeconds { elapsedSeconds = seconds }
        }
        guard phase == .listening else { return }
        let current = now()
        for (channel, stamp) in levelStamps where current.timeIntervalSince(stamp) > Self.levelHold {
            levels[channel] = Self.idleLevel
            levelStamps[channel] = nil
        }
    }

    // MARK: catch-up

    public func catchUp() async {
        guard canCatchUp, let session else { return }
        isSummarizing = true
        recapError = nil
        defer { isSummarizing = false }
        do {
            let value = try await session.recap(minutes: max(1, min(recapMinutes, 60)))
            guard let parsed = LiveRecap(value) else { recapError = "Could not summarize: unexpected reply."; return }
            recap = parsed
            recapUpToEntryID = entries.map(\.id).max() ?? 0
        } catch {
            recapError = "Could not summarize: \(error.localizedDescription)"
        }
    }

    // MARK: transcript navigation and clipboard

    /// Scroll the transcript to an entry and highlight it briefly (a quote chip was activated).
    public func reveal(entry id: Int) {
        guard entries.contains(where: { $0.id == id }) else { return }
        pinnedToLatest = false
        scrollToken += 1
        scrollRequest = ScrollRequest(entryID: id, token: scrollToken)
        highlightedEntryID = id
        highlightClear?.cancel()
        highlightClear = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if !Task.isCancelled { self?.highlightedEntryID = nil }
        }
    }

    public func jumpToLatest() { pinnedToLatest = true }

    public func markCopied() { copied = true }
}
