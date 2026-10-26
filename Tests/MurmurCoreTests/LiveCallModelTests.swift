import Foundation
import XCTest
@testable import MurmurCore

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: Double) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// A call the test drives by hand.
final class ScriptedCall: LiveCallControlling, @unchecked Sendable {
    let isSample: Bool
    private let lock = NSLock()
    private var _status = "idle"
    private var queues: [EventQueue] = []
    var recapReply: JSONValue = [:]
    var recapError: Error?
    var startError: Error?
    var provenance: JSONValue = ["heard": "homelab ASR", "notes": "mercury-2", "notes_host": "api.inceptionlabs.ai"]
    private(set) var recapMinutes: [Int] = []

    init(sample: Bool = false) { isSample = sample }

    var status: String { lock.withLock { _status } }
    func start() throws {
        if let startError { throw startError }
        lock.withLock { _status = "listening" }
        emit(["type": "status", "status": "listening"])
    }
    func stop() async {
        lock.withLock { _status = "stopped" }
        emit(["type": "status", "status": "stopped"])
    }
    func state() -> JSONValue { ["status": .string(status), "provenance": provenance] }
    func subscribe() -> EventQueue { let queue = EventQueue(); lock.withLock { queues.append(queue) }; return queue }
    func unsubscribe(_ queue: EventQueue) {}
    func recap(minutes: Int) async throws -> JSONValue {
        recapMinutes.append(minutes)
        if let recapError { throw recapError }
        return recapReply
    }
    func emit(_ event: JSONValue) { for queue in lock.withLock({ queues }) { queue.put(event) } }
    func say(_ id: Int, _ speaker: String, _ start: Double, _ text: String) {
        emit(["type": "entry", "entry": LiveEntry(id: id, speaker: speaker, start: start, end: start + 2, text: text, backend: "fake").json])
    }
}

@MainActor
final class LiveCallModelTests: XCTestCase {
    func makeModel(_ call: ScriptedCall = ScriptedCall(), clock: TestClock = TestClock(), readiness: [ReadinessRow] = []) -> (LiveCallModel, TestClock) {
        let suite = UserDefaults(suiteName: "live-call-tests-\(UUID().uuidString)")!
        let model = LiveCallModel(makeSession: { call }, makeDemo: { ScriptedCall(sample: true) }, readiness: { readiness },
                                  defaults: suite, now: { clock.now })
        return (model, clock)
    }

    func waitUntil(_ timeout: Double = 5, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    let recapJSON: JSONValue = ["now": "Dates", "points": [["text": "Asked for the date", "entries": [2]]],
                                "asks_of_me": [["text": "Confirm the date", "entry": 2], "plain ask"],
                                "minutes": 5, "entries": 2, "from_s": 600, "to_s": 630]

    func testStatusTransitionsTextAndElapsed() async {
        let call = ScriptedCall()
        let (model, clock) = makeModel(call)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.statusText, "Not listening")
        XCTAssertEqual(model.primaryTitle, "Start call")
        model.startCall()
        XCTAssertEqual(model.phase, .listening)
        XCTAssertEqual(model.statusText, "Listening")
        XCTAssertEqual(model.primaryTitle, "Stop call")
        XCTAssertTrue(model.isCallScreen)
        clock.advance(65)
        model.tick()
        XCTAssertEqual(model.elapsedText, "01:05")
        await model.stopCall()
        XCTAssertEqual(model.phase, .stopped)
        XCTAssertEqual(model.statusText, "Saved · 01:05")
        XCTAssertEqual(model.primaryTitle, "New call")
        XCTAssertNotNil(model.savedMessage)
        clock.advance(30)
        model.tick()
        XCTAssertEqual(model.statusText, "Saved · 01:05")   // the clock stops with the call
        model.newCall()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertNil(model.savedMessage)
    }

    func testSampleCallWording() async {
        let (model, _) = makeModel()
        model.startSample()
        XCTAssertEqual(model.statusText, "Sample call")
        XCTAssertEqual(model.provenanceText, "Sample call · nothing is recorded or sent")
        await model.stopCall()
        XCTAssertEqual(model.statusText, "Sample ended")
        XCTAssertEqual(model.savedMessage, "Sample finished. Nothing was recorded.")
    }

    func testStartFailureStaysIdleWithAMessage() async {
        struct NoKey: LocalizedError { var errorDescription: String? { "no key" } }
        let call = ScriptedCall()
        call.startError = NoKey()
        let (model, _) = makeModel(call)
        model.startCall()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.banner, "Could not start: no key")
        let failing = LiveCallModel(makeSession: { throw NoKey() }, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        failing.startCall()
        XCTAssertEqual(failing.banner, "Could not start: no key")
        XCTAssertFalse(failing.hasSeenCall)
    }

    func testEventsBuildTranscriptNotesAndProvenance() async {
        let call = ScriptedCall()
        let (model, _) = makeModel(call)
        model.startCall()
        XCTAssertEqual(model.provenanceText, "Heard by homelab ASR · Notes by mercury-2, call text goes to api.inceptionlabs.ai")
        call.emit(["type": "partial", "speaker": "them", "text": "we agreed to"])
        call.say(2, "me", 5, "second")
        call.say(1, "them", 1, "first")
        await waitUntil { model.entries.count == 2 }
        XCTAssertEqual(model.entries.map(\.text), ["first", "second"])      // ordered by start time
        call.emit(["type": "context", "context": ["summary": "S", "decisions": [["text": "D", "evidence": [["entry": 1, "quote": "first"]], "proposed": true]],
                                                   "commitments": ["plain"], "open_questions": [], "findings": [], "model": "m", "seconds": 0.5], "error": .null])
        await waitUntil { model.notes != nil }
        XCTAssertEqual(model.notes?.decisions.first?.proposed, true)
        XCTAssertEqual(model.notes?.decisions.first?.evidence.first, LiveQuote(entry: 1, quote: "first"))
        XCTAssertEqual(model.notes?.commitments.first, LiveNoteItem(text: "plain"))
        XCTAssertEqual(model.notes?.commitments.first?.hasQuote, false)
        call.emit(["type": "context", "context": .null, "error": "boom"])
        await waitUntil { model.notesError != nil }
        XCTAssertNotNil(model.notes)    // last good notes stay
        XCTAssertEqual(model.banner, "Notes did not update: boom Showing the last good notes.")
        call.emit(["type": "notice", "text": "Could not capture system audio"])
        call.emit(["type": "notice", "text": "Could not capture system audio"])
        await waitUntil { !model.notices.isEmpty }
        XCTAssertEqual(model.notices, ["Could not capture system audio"])    // de-duplicated
        await model.stopCall()
    }

    func testPartialClearsWhenItsLineArrives() async {
        let call = ScriptedCall()
        let (model, _) = makeModel(call)
        model.startCall()
        call.emit(["type": "partial", "speaker": "them", "text": "hel"])
        await waitUntil { model.partials["them"] == "hel" }
        call.say(1, "them", 1, "hello")
        await waitUntil { model.entries.count == 1 }
        XCTAssertNil(model.partials["them"])
        await model.stopCall()
    }

    func testRecapGoesStaleAsNewLinesArrive() async {
        let call = ScriptedCall()
        call.recapReply = recapJSON
        let (model, _) = makeModel(call)
        XCTAssertFalse(model.canCatchUp)
        model.startCall()
        XCTAssertFalse(model.canCatchUp)          // nothing said yet
        call.say(1, "them", 600, "can you confirm the date")
        call.say(2, "me", 620, "checking")
        await waitUntil { model.entries.count == 2 }
        XCTAssertTrue(model.canCatchUp)
        model.recapMinutes = 10
        await model.catchUp()
        XCTAssertEqual(call.recapMinutes, [10])
        XCTAssertEqual(model.recap?.now, "Dates")
        XCTAssertEqual(model.recap?.asks, [LiveAsk(text: "Confirm the date", entry: 2), LiveAsk(text: "plain ask", entry: nil)])
        XCTAssertEqual(model.recapAsOfText, "As of 10:30 · covers 10:00–10:30")
        XCTAssertEqual(model.recapUpToEntryID, 2)
        XCTAssertFalse(model.isRecapStale)
        XCTAssertNil(model.staleHint)
        call.say(3, "them", 640, "one more")
        await waitUntil { model.entries.count == 3 }
        XCTAssertTrue(model.isRecapStale)
        XCTAssertEqual(model.staleHint, "1 new line. Press Catch me up.")
        call.say(4, "them", 650, "and another")
        await waitUntil { model.entries.count == 4 }
        XCTAssertEqual(model.newLinesSinceRecap, 2)
        XCTAssertEqual(model.staleHint, "2 new lines. Press Catch me up.")
        await model.catchUp()
        XCTAssertEqual(model.newLinesSinceRecap, 0)
        await model.stopCall()
        XCTAssertFalse(model.canCatchUp)         // no catch-up after the call ends
    }

    func testRecapFailureIsShownAndKeepsThePreviousRecap() async {
        struct Down: LocalizedError { var errorDescription: String? { "offline" } }
        let call = ScriptedCall()
        call.recapReply = recapJSON
        let (model, _) = makeModel(call)
        model.startCall()
        call.say(1, "them", 1, "hi")
        await waitUntil { model.entries.count == 1 }
        await model.catchUp()
        call.recapError = Down()
        await model.catchUp()
        XCTAssertEqual(model.recapError, "Could not summarize: offline")
        XCTAssertNotNil(model.recap)
        XCTAssertFalse(model.isSummarizing)
        await model.stopCall()
    }

    func testCopyNotesText() async {
        let call = ScriptedCall()
        let (model, _) = makeModel(call)
        model.startCall()
        call.say(1, "them", 1, "hello there")
        call.say(2, "me", 3, "hi")
        await waitUntil { model.entries.count == 2 }
        XCTAssertEqual(model.notesClipboardText, "them: hello there\nme: hi")     // no notes yet: the transcript
        call.emit(["type": "context", "context": ["summary": "Summary line.",
            "decisions": [["text": "Ship Friday", "evidence": [], "proposed": false]],
            "commitments": [["text": "You send the draft", "evidence": [], "proposed": false], "plain"],
            "open_questions": [["text": "Who owns it?", "evidence": [], "proposed": false]]], "error": .null])
        await waitUntil { model.notes != nil }
        XCTAssertEqual(model.notesClipboardText,
                       "Summary line.\n\nCommitments\n- You send the draft\n- plain\n\nOpen questions\n- Who owns it?\n\nDecisions\n- Ship Friday\n")
        await model.stopCall()
    }

    func testLevelsFallBackToIdleWhenAudioStops() async {
        let call = ScriptedCall()
        let clock = TestClock()
        let (model, _) = makeModel(call, clock: clock)
        model.startCall()
        call.emit(["type": "level", "channel": "them", "level": 0.8])
        await waitUntil { model.levels["them"] == 0.8 }
        clock.advance(0.2)
        model.tick()
        XCTAssertEqual(model.levels["them"], 0.8)
        clock.advance(0.5)
        model.tick()
        XCTAssertEqual(model.levels["them"], LiveCallModel.idleLevel)
        call.emit(["type": "level", "channel": "me", "level": 0])
        await waitUntil { model.levels["me"] != nil }
        XCTAssertEqual(model.levels["me"], LiveCallModel.idleLevel)       // a floor, never an empty bar
        await model.stopCall()
        XCTAssertTrue(model.levels.isEmpty)
    }

    func testRevealUnpinsAndHighlightsOnlyKnownEntries() async {
        let call = ScriptedCall()
        let (model, _) = makeModel(call)
        model.startCall()
        call.say(1, "them", 1, "alpha beta gamma delta epsilon zeta eta theta iota")
        await waitUntil { model.entries.count == 1 }
        model.reveal(entry: 99)
        XCTAssertNil(model.scrollRequest)
        XCTAssertTrue(model.pinnedToLatest)
        model.reveal(entry: 1)
        XCTAssertEqual(model.scrollRequest?.entryID, 1)
        XCTAssertEqual(model.highlightedEntryID, 1)
        XCTAssertFalse(model.pinnedToLatest)
        let first = model.scrollRequest
        model.reveal(entry: 1)
        XCTAssertNotEqual(model.scrollRequest, first)       // same entry again still scrolls
        model.jumpToLatest()
        XCTAssertTrue(model.pinnedToLatest)
        XCTAssertEqual(model.snippet(forEntry: 1), "“alpha beta gamma delta epsilon zeta eta…”")
        XCTAssertEqual(model.snippet(forEntry: 42), "42")
        await model.stopCall()
    }

    func testReadinessGatesStartAndRemembersFirstCall() async {
        let rows = [ReadinessRow(id: "asr", label: "Transcription", state: .ok, detail: "ready"),
                    ReadinessRow(id: "llm", label: "Notes", state: .fail, detail: "No key", fix: "Set INCEPTION_API_KEY")]
        let suite = UserDefaults(suiteName: "live-call-tests-\(UUID().uuidString)")!
        let model = LiveCallModel(makeSession: { ScriptedCall() }, readiness: { rows }, defaults: suite)
        XCTAssertFalse(model.hasSeenCall)
        await model.refreshReadiness()
        XCTAssertEqual(model.readiness, rows)
        XCTAssertFalse(model.canStart)
        XCTAssertFalse(model.primaryEnabled)
        model.startSample()
        XCTAssertTrue(model.hasSeenCall)
        XCTAssertTrue(LiveCallModel(makeSession: { ScriptedCall() }, defaults: suite).hasSeenCall)
        await model.stopCall()
    }

    func testCaptureFailureReportedByTheHostAppShowsAsABanner() async {
        let (model, _) = makeModel()
        model.startCall()
        model.report("Could not capture audio: permission denied")
        XCTAssertEqual(model.banner, "Could not capture audio: permission denied")
    }

    func testRealSampleCallEndToEndThroughTheModel() async {
        let suite = UserDefaults(suiteName: "live-call-tests-\(UUID().uuidString)")!
        let model = LiveCallModel(makeSession: { ScriptedCall() }, makeDemo: { DemoSession(speed: 60) }, defaults: suite)
        model.startSample()
        await waitUntil(15) { model.phase == .stopped }
        XCTAssertEqual(model.phase, .stopped)
        XCTAssertEqual(model.entries.count, 9)
        XCTAssertEqual(model.notes?.decisions.last?.proposed, true)
        XCTAssertEqual(model.notes?.decisions.first?.evidence.first?.entry, 3)
        XCTAssertEqual(model.provenance["heard"], "sample")
        XCTAssertEqual(model.statusText, "Sample ended")
    }
}

final class LiveNotesParsingTests: XCTestCase {
    func testRecapParsesAsksAndWindow() {
        let recap = LiveRecap(["now": "n", "points": [["text": "p", "entries": [1, 2]]], "asks_of_me": [["text": "a", "entry": .null]],
                               "minutes": 5, "entries": 3, "from_s": 1.5, "to_s": 9])
        XCTAssertEqual(recap?.points.first?.entries, [1, 2])
        XCTAssertEqual(recap?.asks, [LiveAsk(text: "a", entry: nil)])
        XCTAssertEqual(recap?.fromSeconds, 1.5)
        XCTAssertNil(LiveRecap(nil))
        XCTAssertNil(LiveNotes(.null))
    }

    func testClockFormatting() {
        XCTAssertEqual(LiveEntry.clock(0), "00:00")
        XCTAssertEqual(LiveEntry.clock(59.9), "00:59")
        XCTAssertEqual(LiveEntry.clock(630), "10:30")
        XCTAssertEqual(LiveEntry.clock(-3), "00:00")
    }

    func testReadinessRowRoundTrip() {
        let row = ReadinessRow(id: "mic", label: "Microphone", state: .warn, detail: "d", fix: "f")
        XCTAssertEqual(ReadinessRow(row.json), row)
    }
}

final class LivePCMTests: XCTestCase {
    func pcm(_ values: [Int16]) -> Data {
        var data = Data()
        for value in values { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        return data
    }

    func samples(_ data: Data) -> [Int16] {
        stride(from: 0, to: data.count - 1, by: 2).map { Int16(bitPattern: UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8) }
    }

    func testResamples24kTo16kKeepingLevelAndRatio() {
        var resampler = LinearResampler(from: 24000, to: 16000)
        let out = samples(resampler.process(pcm([Int16](repeating: 1000, count: 2400))))
        XCTAssertEqual(Double(out.count), 1600, accuracy: 2)
        XCTAssertTrue(out.allSatisfy { $0 == 1000 })
    }

    func testChunkBoundariesDoNotChangeTheOutput() {
        let input = (0..<2400).map { Int16(8000 * sin(Double($0) / 7)) }
        var whole = LinearResampler(from: 24000, to: 16000)
        let reference = samples(whole.process(pcm(input)))
        var pieces = LinearResampler(from: 24000, to: 16000)
        var joined: [Int16] = []
        var index = 0
        for size in [1, 7, 480, 3, 1000, 909] {
            let end = min(input.count, index + size)
            joined += samples(pieces.process(pcm(Array(input[index..<end]))))
            index = end
        }
        XCTAssertEqual(joined, reference)
    }

    func testQueueSourceDeliversThenEnds() {
        let started = LockedFlag()
        let source = QueuePCMSource(onStart: { started.set() })
        XCTAssertNoThrow(try source.start())
        XCTAssertTrue(started.value)
        source.push(Data([1, 2]))
        source.push(Data([3, 4]))
        XCTAssertEqual(source.nextChunk(), Data([1, 2]))
        source.finish()
        XCTAssertEqual(source.nextChunk(), Data([3, 4]))     // remaining audio is still delivered
        XCTAssertNil(source.nextChunk())
    }

    func testQueueSourceFeedsASessionLikeAnyOtherSource() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let mic = QueuePCMSource(), system = QueuePCMSource()
        let session = LiveSession(root: tmp, asr: FakeLiveASR(), agent: CountingAgent(), channels: ["mic", "system"],
                                  sourceFactory: { $0 == "mic" ? mic : system }, minInterval: 0)
        try session.start()
        mic.push(liveSilence(0.5) + liveTone(1) + liveSilence(1))
        system.push(liveSilence(0.5) + liveTone(1) + liveSilence(1))
        await session.stop()    // stopping the sources ends both channels
        XCTAssertEqual(session.transcript.snapshot().map(\.speaker).sorted(), ["me", "them"])
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}
