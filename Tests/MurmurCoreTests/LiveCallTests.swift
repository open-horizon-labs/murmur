import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MurmurCore

// Port of call-memory's tests/test_live.py, with fakes (no network, no audio devices).

func liveTone(_ seconds: Double, amplitude: Double = 8000) -> Data {
    var data = Data()
    for index in 0..<Int(16000 * seconds) {
        var sample = Int16(amplitude * sin(Double(index) / 5)).littleEndian
        withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
    }
    return data
}

func liveSilence(_ seconds: Double) -> Data { Data(count: Int(16000 * seconds) * 2) }

func sample16(_ value: Int16, count: Int = 1) -> Data {
    var data = Data()
    for _ in 0..<count { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
    return data
}

func firstSample(_ data: Data) -> Int16 { Int16(bitPattern: UInt16(data[data.startIndex]) | UInt16(data[data.startIndex + 1]) << 8) }

final class LiveEndpointerTests: XCTestCase {
    func testUtterancesBlipsAndLongSpeech() {
        var endpointer = Endpointer()
        let events = endpointer.feed(liveSilence(1) + liveTone(1) + liveSilence(1) + liveTone(0.05) + liveSilence(1) + liveTone(26) + liveSilence(1))
        var kinds: [String] = []
        var starts: [Double] = []
        for event in events {
            switch event {
            case .start(let offset): kinds.append("start"); starts.append(offset)
            case .end: kinds.append("end")
            case .cancel: kinds.append("cancel")
            case .audio: break
            }
        }
        XCTAssertEqual(kinds, ["start", "end", "start", "end", "start", "end"])   // blip never starts
        XCTAssertEqual((starts[0] * 10).rounded() / 10, 0.7)                       // one second in, minus 300 ms pre-roll
        XCTAssertEqual(starts[2], 28.8, accuracy: 0.2)                              // cut at 25 s, speech continues
    }

    func testShortNoiseIsCancelled() {
        var endpointer = Endpointer(startFrames: 2, minMs: 400)
        let events = endpointer.feed(liveSilence(1) + liveTone(0.1) + liveSilence(1))
        XCTAssertTrue(events.contains { if case .cancel = $0 { true } else { false } })
    }

    func testFlushClosesOpenUtterance() {
        var endpointer = Endpointer()
        _ = endpointer.feed(liveSilence(0.2) + liveTone(1))
        XCTAssertEqual(endpointer.flush().count, 1)
        XCTAssertTrue(endpointer.flush().isEmpty)
    }
}

final class LiveMixerTests: XCTestCase {
    func testWaitsForSlowChannelThenPads() {
        var mixer = Mixer(["a", "b"], maxLagSeconds: 0.5)
        mixer.add("a", sample16(100, count: 100))
        mixer.add("b", sample16(50, count: 40))
        XCTAssertEqual(firstSample(mixer.drain()), 150)
        XCTAssertEqual(mixer.drain().count, 0)
        XCTAssertEqual(mixer.drain(final: true).count, 120)
    }

    func testClipsInsteadOfWrapping() {
        var mixer = Mixer(["a", "b"])
        mixer.add("a", sample16(30000))
        mixer.add("b", sample16(30000))
        XCTAssertEqual(firstSample(mixer.drain()), 32767)
        mixer.add("a", sample16(-30000))
        mixer.add("b", sample16(-30000))
        XCTAssertEqual(firstSample(mixer.drain()), -32768)
    }
}

// MARK: - ASR

final class FakeBackend: ASRBackend, @unchecked Sendable {
    let name: String
    private let fail: Int
    private let text: String
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }

    init(_ name: String, fail: Int = 0, text: String = "hello") { self.name = name; self.fail = fail; self.text = text }

    func open(onPartial: PartialHandler?) async throws -> any BackendStream { throw ASRError.busy }

    func transcribe(pcm: Data, onPartial: PartialHandler?) async throws -> String {
        let attempt = lock.withLock { count += 1; return count }
        if attempt <= fail { throw ASRError.busy }
        return text
    }
}

final class LiveResilientTests: XCTestCase {
    func testBusyPrimaryIsReplayedWithoutLosingAudio() async throws {
        let primary = FakeBackend("homelab", fail: 2)
        let asr = ResilientASR(primary: primary, fallback: nil, sleep: { _ in })
        let stream = asr.open(onPartial: nil)
        stream.send(Data(count: 3200))
        let result = try await stream.finish()
        XCTAssertEqual(result.text, "hello")
        XCTAssertEqual(result.backend, "homelab")
        XCTAssertEqual(primary.calls, 3)
    }

    func testCloudFallbackOnlyWhenAllowed() async throws {
        let down = FakeBackend("homelab", fail: 99)
        do {
            _ = try await ResilientASR(primary: down, fallback: nil, retries: 2, sleep: { _ in }).replay(Data(count: 2))
            XCTFail("expected ASRError")
        } catch is ASRError {}
        let cloud = FakeBackend("openai", text: "from cloud")
        let asr = ResilientASR(primary: down, fallback: cloud, retries: 2, sleep: { _ in })
        let result = try await asr.replay(Data(count: 2))
        XCTAssertEqual(result.text, "from cloud")
        XCTAssertEqual(result.backend, "openai")
        XCTAssertTrue(asr.isDegraded)
    }

    func testBuildASRRequiresABackend() throws {
        let live = LiveSettings()
        XCTAssertThrowsError(try LiveConfig.buildASR(live, env: [:]))
        XCTAssertNoThrow(try LiveConfig.buildASR(live, env: ["CALL_MEMORY_ASR_URL": "ws://x:1"]))
    }

    func testStreamsThroughAWorkingPrimaryWithPartials() async throws {
        let socket = FakeSocket(script: [.ready, .partialOnBinary("hel"), .finalOnEnd("hello there")])
        let backend = HomelabASR(url: "ws://host:8011", connect: { _ in socket })
        let partials = PartialLog()
        let asr = ResilientASR(primary: backend, fallback: nil, sleep: { _ in })
        let stream = asr.open(onPartial: { partials.add($0) })
        stream.send(Data(count: 640))
        stream.send(Data(count: 640))
        let result = try await stream.finish()
        XCTAssertEqual(result.text, "hello there")
        XCTAssertEqual(result.backend, "homelab")
        XCTAssertEqual(partials.values.last, "hel")
        XCTAssertEqual(socket.sentBinary, 2)
        let start = JSONValue.parse(socket.sentText.first ?? "")
        XCTAssertEqual(start?["type"]?.stringValue, "start")
        XCTAssertEqual(start?["sample_rate"]?.intValue, 16000)
        XCTAssertEqual(start?["format"]?.stringValue, "pcm_s16le")
        XCTAssertEqual(start?["language"]?.stringValue, "en-US")
        XCTAssertEqual(socket.sentText.last, #"{"type":"end"}"#)
    }
}

final class LiveHomelabTests: XCTestCase {
    func testStreamURLAndBusyHandshake() async {
        XCTAssertEqual(HomelabASR(url: "ws://192.168.1.104:8011/").url.absoluteString, "ws://192.168.1.104:8011/v1/audio/stream")
        let busy = FakeSocket(script: [.line(#"{"type":"error","error":"service busy","retry_after":1}"#)])
        do {
            _ = try await HomelabASR(url: "ws://h:1", connect: { _ in busy }).open(onPartial: nil)
            XCTFail("expected busy")
        } catch { XCTAssertEqual(error as? ASRError, .busy) }
    }

    func testUnreachableAndUnexpectedHandshakeAreErrors() async {
        struct Down: Error {}
        do {
            _ = try await HomelabASR(url: "ws://h:1", connect: { _ in throw Down() }).open(onPartial: nil)
            XCTFail("expected failure")
        } catch { XCTAssertEqual(error as? ASRError, .failed("homelab ASR unreachable (Down)")) }
        let odd = FakeSocket(script: [.line(#"{"type":"hello"}"#)])
        do {
            _ = try await HomelabASR(url: "ws://h:1", connect: { _ in odd }).open(onPartial: nil)
            XCTFail("expected failure")
        } catch { XCTAssertEqual(error as? ASRError, .failed("unexpected ASR handshake")) }
    }

    func testErrorBeforeFinalFailsTheStream() async throws {
        let socket = FakeSocket(script: [.ready, .lineOnEnd(#"{"type":"error","error":"too long"}"#)])
        let stream = try await HomelabASR(url: "ws://h:1", connect: { _ in socket }).open(onPartial: nil)
        do {
            _ = try await stream.finish()
            XCTFail("expected failure")
        } catch { XCTAssertEqual(error as? ASRError, .failed("too long")) }
    }
}

final class PartialLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ text: String) { lock.withLock { items.append(text) } }
    var values: [String] { lock.withLock { items } }
}

enum FakeStep: Sendable {
    case ready
    case line(String)
    case partialOnBinary(String)
    case finalOnEnd(String)
    case lineOnEnd(String)
}

/// A scripted homelab ASR socket: ready/partial/final events appear in response to what the client sends.
final class FakeSocket: ASRSocket, @unchecked Sendable {
    private let lock = NSLock()
    private let stream: AsyncStream<String?>
    private let continuation: AsyncStream<String?>.Continuation
    private var iterator: AsyncStream<String?>.Iterator
    private var steps: [FakeStep]
    private var binary = 0
    private var texts: [String] = []
    var sentBinary: Int { lock.withLock { binary } }
    var sentText: [String] { lock.withLock { texts } }

    init(script: [FakeStep]) {
        (stream, continuation) = AsyncStream<String?>.makeStream()
        iterator = stream.makeAsyncIterator()
        steps = script
        for step in script { if case .line(let text) = step { continuation.yield(text) } }
    }

    func sendText(_ text: String) async throws {
        let isEnd = lock.withLock { texts.append(text); return text.contains(#""end""#) }
        let parsed = JSONValue.parse(text)
        if parsed?["type"]?.stringValue == "start" {
            if lock.withLock({ steps.contains { if case .ready = $0 { true } else { false } } }) {
                continuation.yield(#"{"type":"ready"}"#)
            }
        }
        if isEnd {
            let finals: [String] = lock.withLock { steps.compactMap { if case .finalOnEnd(let text) = $0 { text } else { nil } } }
            for text in finals { continuation.yield(JSONValue.object(["type": "final", "text": .string(text)]).jsonText) }
            let lines: [String] = lock.withLock { steps.compactMap { if case .lineOnEnd(let text) = $0 { text } else { nil } } }
            for text in lines { continuation.yield(text) }
        }
    }

    func sendBinary(_ data: Data) async throws {
        let partials: [String] = lock.withLock { binary += 1; return steps.compactMap { if case .partialOnBinary(let text) = $0 { text } else { nil } } }
        for text in partials { continuation.yield(JSONValue.object(["type": "partial", "text": .string(text)]).jsonText) }
    }

    func receiveText() async throws -> String? {
        var local = lock.withLock { iterator }
        let value = await local.next()
        lock.withLock { iterator = local }
        return value ?? nil
    }

    func close() async { continuation.finish() }
}

// MARK: - Context

final class LiveContextTests: XCTestCase {
    func snapshot() -> [LiveEntry] {
        let transcript = LiveTranscript()
        transcript.add(speaker: "them", start: 1, end: 2, text: "We agreed to ship the report on Friday.")
        transcript.add(speaker: "me", start: 3, end: 4, text: "I will send the draft tomorrow.")
        return transcript.snapshot()
    }

    func testOnlyQuotesTheModelActuallySawAreKept() {
        let box = ToolBox(snapshot())
        box.show(Array(box.snapshot[..<1]))
        let raw: JSONValue = ["summary": "s", "findings": [["title": "t", "detail": "d", "evidence": [
            ["entry": 1, "quote": "ship the report on friday"],     // seen, real
            ["entry": 2, "quote": "I will send the draft"],         // real but never shown
            ["entry": 1, "quote": "ship it on Monday"],             // fabricated
            ["entry": 99, "quote": "x"]]]]]
        let evidence = LiveContextTools.validate(raw, box)["findings"]?.arrayValue?.first?["evidence"]?.arrayValue ?? []
        XCTAssertEqual(evidence.compactMap { $0["entry"]?.intValue }, [1])
    }

    func testNotesCarryVerifiedQuotesAndProposedFlag() {
        let box = ToolBox(snapshot())
        box.show(box.snapshot)
        let raw: JSONValue = ["summary": "s", "decisions": [
            ["text": "Ship Friday", "entry": 1, "quote": "ship the report on Friday", "proposed": false],
            ["text": "Maybe Monday", "entry": 1, "quote": "ship it Monday", "proposed": true]],
            "commitments": ["plain string stays"], "open_questions": [["text": "no quote", "entry": 2]]]
        let out = LiveContextTools.validate(raw, box)
        XCTAssertEqual(out["decisions"]?.arrayValue?[0]["evidence"]?.arrayValue?.first?["entry"]?.intValue, 1)
        XCTAssertEqual(out["decisions"]?.arrayValue?[1]["evidence"]?.arrayValue?.count, 0)    // fabricated quote dropped
        XCTAssertEqual(out["decisions"]?.arrayValue?[1]["proposed"]?.boolValue, true)
        XCTAssertEqual(out["commitments"]?.arrayValue?[0], ["text": "plain string stays", "evidence": [], "proposed": false])
        XCTAssertEqual(out["open_questions"]?.arrayValue?[0]["evidence"]?.arrayValue?.count, 0)
    }

    func testQuoteOnAnEntryTheModelNeverSawIsDropped() {
        let box = ToolBox(snapshot())
        box.show(Array(box.snapshot[..<1]))
        let raw: JSONValue = ["decisions": [["text": "d", "entry": 2, "quote": "send the draft tomorrow"]],
                              "commitments": [["text": "c", "entry": 1, "quote": "ship the report"]]]
        let out = LiveContextTools.validate(raw, box)
        XCTAssertEqual(out["decisions"]?.arrayValue?[0]["evidence"]?.arrayValue?.count, 0)
        XCTAssertEqual(out["commitments"]?.arrayValue?[0]["evidence"]?.arrayValue?.count, 1)
    }

    func testPromptsAddressTheUserAsYouAndAskForObjects() {
        XCTAssertTrue(LiveContextTools.system.contains("call them 'you', never 'me'"))
        XCTAssertTrue(LiveContextTools.system.contains(#""decisions": [{"text": str, "entry": int, "quote": str, "proposed": bool}]"#))
        XCTAssertTrue(LiveContextTools.recapSystem.contains("call them 'you'") || LiveContextTools.recapSystem.contains("call you") || LiveContextTools.recapSystem.contains("Write to the user: call them 'you'"))
        XCTAssertTrue(LiveContextTools.recapSystem.contains(#""asks_of_me": [{"text": str, "entry": int}]"#))
    }

    func testToolLoopThenJSON() async throws {
        let client = ScriptedChat([
            ["content": .null, "tool_calls": [["id": "1", "function": ["name": "search_transcript", "arguments": #"{"query": "draft"}"#]]]],
            ["content": #"Notes: {"summary": "draft promised", "commitments": ["me: send draft"], "findings": [{"title": "Draft", "detail": "d", "evidence": [{"entry": 2, "quote": "send the draft tomorrow"}]}]}"#]
        ])
        let snap = snapshot()
        let result = try await ContextAgent(client: client, recent: 0).run(snapshot: snap, previous: nil)
        XCTAssertEqual(result["findings"]?.arrayValue?.first?["evidence"]?.arrayValue?.first?["entry"]?.intValue, 2)   // seen via the tool
        XCTAssertEqual(result["through_entry"]?.intValue, snap.last?.id)
        XCTAssertEqual(result["model"]?.stringValue, "fake:model")
        XCTAssertEqual(client.requests.count, 2)
        XCTAssertEqual(client.requests[1].last?["role"]?.stringValue, "tool")
    }

    func testInvalidReplyIsRetriedOnceWithAReminder() async throws {
        let client = ScriptedChat([["content": "sorry, no json"], ["content": #"{"summary": "ok"}"#]])
        let result = try await ContextAgent(client: client).run(snapshot: snapshot(), previous: nil)
        XCTAssertEqual(result["summary"]?.stringValue, "ok")
        XCTAssertEqual(client.requests[1].last?["content"]?.stringValue, "Reply with the JSON object only.")
    }

    func testToolsReadAndSearch() {
        let box = ToolBox(snapshot())
        XCTAssertEqual(box.run("read_transcript", ["entry": 99]), "no such entry")
        XCTAssertTrue(box.run("read_transcript", ["entry": 1, "after": 5]).contains("[2] me"))
        XCTAssertEqual(box.run("search_transcript", ["query": "report friday"]).hasPrefix("[1] them 00:01"), true)
        XCTAssertEqual(box.run("search_transcript", ["query": "unrelated"]), "no matches")
        XCTAssertEqual(box.run("nope", [:]), "unknown tool")
        XCTAssertEqual(box.seen, [1, 2])
    }

    func testTranscriptOrdersByStartTime() {
        let transcript = LiveTranscript()
        transcript.add(speaker: "me", start: 5, end: 6, text: "second")
        transcript.add(speaker: "them", start: 1, end: 2, text: "first")
        XCTAssertEqual(transcript.snapshot().map(\.text), ["first", "second"])
    }

    func testUpdaterCoalescesAndPublishesNewestTranscript() async throws {
        let transcript = LiveTranscript()
        transcript.add(speaker: "me", start: 0, end: 1, text: "one")
        let published = PartialLog()
        let updater = ContextUpdater(transcript: transcript, agent: CountingAgent(), minInterval: 0) { context, _ in
            published.add(context?["summary"]?.stringValue ?? "")
        }
        updater.notify()
        transcript.add(speaker: "me", start: 2, end: 3, text: "two")
        await updater.finish(timeout: 5)
        XCTAssertEqual(published.values.last, "2 entries")
        XCTAssertEqual(updater.context?["summary"]?.stringValue, "2 entries")
    }

    func testFailedRunKeepsLastGoodContext() async throws {
        let transcript = LiveTranscript()
        transcript.add(speaker: "me", start: 0, end: 1, text: "one")
        let agent = FlakyAgent()
        let errors = PartialLog()
        let updater = ContextUpdater(transcript: transcript, agent: agent, minInterval: 0) { _, error in errors.add(error ?? "") }
        updater.notify()
        await updater.finish(timeout: 5)
        agent.fail = true
        updater.notify()
        await updater.finish(timeout: 5)
        XCTAssertEqual(updater.context?["summary"]?.stringValue, "good")
        XCTAssertNotNil(updater.error)
    }
}

final class LiveRecapTests: XCTestCase {
    func testWindowIsCallTimeAndCitationsAreFiltered() async throws {
        let transcript = LiveTranscript()
        transcript.add(speaker: "them", start: 0, end: 10, text: "old topic budget")
        transcript.add(speaker: "them", start: 600, end: 610, text: "can you confirm the date")
        transcript.add(speaker: "me", start: 620, end: 630, text: "checking")
        let client = ScriptedChat([["content": #"{"now": "date", "points": [{"text": "asked for date", "entries": [2, 1, 99]}], "asks_of_me": ["confirm the date", {"text": "answer Dana", "entry": 3}, {"text": "old", "entry": 1}]}"#]])
        let result = try await LiveContextTools.recap(client: client, snapshot: transcript.snapshot(), minutes: 5)
        let prompt = client.requests[0][1]["content"]?.stringValue ?? ""
        XCTAssertFalse(prompt.contains("old topic"))                    // outside the 5-minute window
        XCTAssertEqual(result["points"]?.arrayValue?.first?["entries"]?.arrayValue?.compactMap(\.intValue), [2])   // 1 outside the window, 99 absent
        let asks = result["asks_of_me"]?.arrayValue ?? []
        XCTAssertEqual(asks[0], ["text": "confirm the date", "entry": .null])
        XCTAssertEqual(asks[1], ["text": "answer Dana", "entry": 3])
        XCTAssertEqual(asks[2], ["text": "old", "entry": .null])          // entry 1 is outside the window
        XCTAssertEqual(result["from_s"]?.doubleValue, 600)
        XCTAssertEqual(result["to_s"]?.doubleValue, 630)
        XCTAssertEqual(result["entries"]?.intValue, 2)
        let empty = try await LiveContextTools.recap(client: client, snapshot: [], minutes: 5)
        XCTAssertEqual(empty["points"]?.arrayValue?.count, 0)
        XCTAssertEqual(empty["from_s"]?.doubleValue, 0)
        XCTAssertEqual(empty["to_s"]?.doubleValue, 0)
    }
}

final class ScriptedChat: LiveChat, @unchecked Sendable {
    let label = "fake:model"
    private let lock = NSLock()
    private var replies: [JSONValue]
    private var seen: [[JSONValue]] = []
    var requests: [[JSONValue]] { lock.withLock { seen } }

    init(_ replies: [JSONValue]) { self.replies = replies }

    func complete(messages: [JSONValue], tools: JSONValue?, maxTokens: Int) async throws -> JSONValue {
        lock.withLock {
            seen.append(messages)
            return replies.isEmpty ? [:] : replies.removeFirst()
        }
    }
}

struct CountingAgent: LiveContextAgent {
    func run(snapshot: [LiveEntry], previous: JSONValue?) async throws -> JSONValue {
        ["summary": .string("\(snapshot.count) entries"), "through_entry": JSONValue(snapshot.last?.id ?? 0), "findings": []]
    }
    func recap(snapshot: [LiveEntry], minutes: Int) async throws -> JSONValue { ["now": "fake"] }
}

final class FlakyAgent: LiveContextAgent, @unchecked Sendable {
    private let lock = NSLock()
    private var _fail = false
    var fail: Bool { get { lock.withLock { _fail } } set { lock.withLock { _fail = newValue } } }
    struct Boom: Error {}
    func run(snapshot: [LiveEntry], previous: JSONValue?) async throws -> JSONValue {
        if fail { throw Boom() }
        return ["summary": "good"]
    }
    func recap(snapshot: [LiveEntry], minutes: Int) async throws -> JSONValue { [:] }
}

// MARK: - Session

final class FakeSource: PCMSource, @unchecked Sendable {
    private let lock = NSLock()
    private var delivered = false
    func start() throws {}
    func nextChunk() -> Data? {
        let first = lock.withLock { () -> Bool in defer { delivered = true }; return !delivered }
        return first ? liveSilence(0.5) + liveTone(1) + liveSilence(1) : nil
    }
    func stop() {}
}

final class FakeLiveASR: LiveASR, @unchecked Sendable {
    var isDegraded: Bool { false }
    func open(onPartial: PartialHandler?) -> any LiveASRStream { Stream(onPartial: onPartial) }

    final class Stream: LiveASRStream, @unchecked Sendable {
        let onPartial: PartialHandler?
        init(onPartial: PartialHandler?) { self.onPartial = onPartial }
        func send(_ pcm: Data) { onPartial?("partial") }
        func finish() async throws -> (text: String, backend: String) { ("we agreed to ship on Friday", "fake") }
        func close() {}
    }
}

final class LiveSessionTests: XCTestCase {
    func testCallIsTranscribedSavedAndStagedForSync() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("root")
        let session = LiveSession(root: root, asr: FakeLiveASR(), agent: CountingAgent(), channels: ["mic", "system"],
                                  sourceFactory: { _ in FakeSource() }, minInterval: 0,
                                  provenance: ["heard": "homelab ASR", "notes": "mercury-2", "notes_host": "api.inceptionlabs.ai"])
        let events = session.subscribe()
        try session.start()
        await session.stop()
        XCTAssertEqual(session.state()["provenance"], ["heard": "homelab ASR", "notes": "mercury-2", "notes_host": "api.inceptionlabs.ai"])
        let entries = session.transcript.snapshot()
        XCTAssertEqual(entries.map(\.speaker).sorted(), ["me", "them"])
        XCTAssertEqual(session.context?["summary"]?.stringValue, "2 entries")
        XCTAssertEqual(session.status, "stopped")

        let saved = try XCTUnwrap(JSONValue.parse(try Data(contentsOf: session.directory.appendingPathComponent("session.json"))))
        XCTAssertEqual(saved["status"]?.stringValue, "complete")
        XCTAssertEqual(saved["entries"]?.arrayValue?.count, 2)
        let text = try String(contentsOf: session.directory.appendingPathComponent("transcript.txt"), encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("[1]"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.directory.appendingPathComponent("audio.pcm").path))   // staged, not left behind

        // The staged recording and manifest follow the contract the upload step reads.
        let device = LiveStaging.deviceID()
        let folder = root.appendingPathComponent("incoming").appendingPathComponent(device)
        let wav = folder.appendingPathComponent("\(session.id).wav")
        let manifest = try XCTUnwrap(JSONValue.parse(try Data(contentsOf: folder.appendingPathComponent("\(session.id).wav.manifest.json"))))
        let wavData = try Data(contentsOf: wav)
        XCTAssertEqual(manifest["schema_version"]?.intValue, 1)
        XCTAssertEqual(manifest["device"]?["serial_number"]?.stringValue, device)
        XCTAssertEqual(manifest["device"]?["model"]?.stringValue, "call-memory-live")
        XCTAssertEqual(manifest["recording"]?["id"]?.stringValue, session.id)
        XCTAssertEqual(manifest["recording"]?["filename"]?.stringValue, "\(session.id).wav")
        XCTAssertEqual(manifest["recording"]?["size"]?.intValue, wavData.count)
        XCTAssertEqual(manifest["recording"]?["sha256"]?.stringValue, SHA256Digest.hex(wavData))
        XCTAssertEqual(manifest["recording"]?["object_key"]?.stringValue, "recordings/incoming/\(device)/\(session.id).wav")
        XCTAssertEqual(manifest["recording"]?["signature"], .null)
        XCTAssertEqual(saved["recording"]?.stringValue, manifest["recording"]?["object_key"]?.stringValue)
        XCTAssertEqual(String(decoding: wavData.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertGreaterThan(wavData.count, 16000 * 2)

        var kinds: [String] = []
        var levels: [(String, Double)] = []
        while let event = events.get(timeout: 0.01) {
            kinds.append(event["type"]?.stringValue ?? "")
            if event["type"]?.stringValue == "level", let channel = event["channel"]?.stringValue, let level = event["level"]?.doubleValue {
                levels.append((channel, level))
            }
        }
        XCTAssertEqual(Set(levels.map(\.0)), ["me", "them"])
        XCTAssertTrue(levels.allSatisfy { (0...1).contains($0.1) })
        XCTAssertTrue(kinds.contains("entry") && kinds.contains("context") && kinds.contains("partial") && kinds.contains("status"))
    }

    func testMissingCaptureIsReportedAndOtherChannelContinues() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        struct NoParec: Error {}
        let session = LiveSession(root: tmp, asr: FakeLiveASR(), agent: CountingAgent(), channels: ["mic", "system"],
                                  sourceFactory: { kind in if kind == "system" { throw NoParec() }; return FakeSource() }, minInterval: 0)
        try session.start()
        await session.stop()
        XCTAssertEqual(session.notices, ["Could not capture system audio (NoParec); continuing without it."])
        XCTAssertEqual(session.transcript.snapshot().map(\.speaker), ["me"])
    }

    func testNoSourceAtAllFailsToStart() {
        struct Nope: Error {}
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let session = LiveSession(root: tmp, asr: FakeLiveASR(), agent: CountingAgent(), channels: ["mic"], sourceFactory: { _ in throw Nope() })
        XCTAssertThrowsError(try session.start())
        XCTAssertEqual(session.status, "stopped")
    }

    func testCrashedCallAudioIsRecoveredFromRawPCM() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dir = tmp.appendingPathComponent("live").appendingPathComponent("crashed")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try liveTone(2).write(to: dir.appendingPathComponent("audio.pcm"))
        try LiveStaging.writeJSON(["id": "crashed", "started_at": "2026-01-01T00:00:00.000000+00:00", "status": "recording"], to: dir.appendingPathComponent("session.json"))
        XCTAssertEqual(LiveStaging.recoverPartials(root: tmp), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("audio.pcm").path))
        let staged = tmp.appendingPathComponent("incoming").appendingPathComponent(LiveStaging.deviceID()).appendingPathComponent("crashed.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertEqual(LiveStaging.recoverPartials(root: tmp), 0)
    }

    func testShortRecordingIsNotStaged() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let pcm = tmp.appendingPathComponent("audio.pcm")
        try liveTone(0.5).write(to: pcm)
        XCTAssertNil(try LiveStaging.stageRecording(root: tmp, sessionID: "x", pcmURL: pcm, startedAt: "t"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pcm.path))
    }
}

// MARK: - Settings, keys, chat, cloud ASR

final class LiveSettingsTests: XCTestCase {
    func testDefaultsValidateAndHoldNoSecret() throws {
        let settings = LiveSettings.load(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        XCTAssertNoThrow(try settings.validate())
        XCTAssertFalse(LiveSettings.defaultsJSON.jsonText.contains("sk-"))
        XCTAssertEqual(settings.llm.model, "mercury-2")
        XCTAssertEqual(settings.llm.baseURL, "https://api.inceptionlabs.ai/v1")
        XCTAssertEqual(settings.llm.reasoningEffort, "low")
    }

    func testBadValuesRejected() {
        var settings = LiveSettings()
        settings.channels = []
        XCTAssertThrowsError(try settings.validate())
        settings = LiveSettings()
        settings.homelabURL = "http://nope"
        XCTAssertThrowsError(try settings.validate())
        settings.homelabURL = "ws://host:8011"
        XCTAssertNoThrow(try settings.validate())
    }

    func testSettingsFileOverlaysDefaults() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"live": {"channels": ["mic"], "llm": {"model": "other"}, "asr": {"homelab_url": "ws://h:8011"}}}"#.utf8).write(to: root.appendingPathComponent("settings.json"))
        let settings = LiveSettings.load(root: root)
        XCTAssertEqual(settings.channels, ["mic"])
        XCTAssertEqual(settings.llm.model, "other")
        XCTAssertEqual(settings.llm.baseURL, "https://api.inceptionlabs.ai/v1")   // untouched default
        XCTAssertEqual(settings.homelabURL, "ws://h:8011")
    }

    func testEnvFileDoesNotOverride() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).env")
        defer { try? FileManager.default.removeItem(at: path) }
        try Data("A=1\nB='two'\n# c\n".utf8).write(to: path)
        var env = ["A": "keep"]
        LiveConfig.loadEnvFile(path, into: &env)
        XCTAssertEqual(env, ["A": "keep", "B": "two"])
    }

    func testPlatformCommands() throws {
        XCTAssertTrue(try LiveCapture.sourceCommand("system", platform: "linux").contains("--device=@DEFAULT_MONITOR@"))
        XCTAssertTrue(try LiveCapture.sourceCommand("mic", platform: "linux").contains("--device=@DEFAULT_SOURCE@"))
        XCTAssertEqual(try LiveCapture.sourceCommand("mic", platform: "darwin")[0], "ffmpeg")
        XCTAssertThrowsError(try LiveCapture.sourceCommand("mic", platform: "plan9"))
    }

    func testKeyFromEnvironmentOrCommandNeverFromSettings() throws {
        XCTAssertEqual(try LiveKeys.resolve(keyEnv: "K", keyCommand: [], env: ["K": " secret \n"]), "secret")
        XCTAssertThrowsError(try LiveKeys.resolve(keyEnv: "K", keyCommand: [], env: [:]))
        XCTAssertEqual(try LiveKeys.resolve(keyEnv: "K", keyCommand: ["echo", "from-command"], env: [:]), "from-command")
        XCTAssertThrowsError(try LiveKeys.resolve(keyEnv: "K", keyCommand: ["false"], env: [:]))
    }

    func testReadinessRows() async {
        var live = LiveSettings()
        live.channels = ["mic"]
        let missingKey = await LiveReadiness.readiness(live, env: ["CALL_MEMORY_ASR_URL": "ws://h:8011"], platform: "linux", health: { _ in Data(#"{"busy": false}"#.utf8) })
        XCTAssertEqual(missingKey["can_start"]?.boolValue, false)   // no INCEPTION_API_KEY
        let rows = missingKey["rows"]?.arrayValue ?? []
        XCTAssertEqual(rows.first { $0["id"]?.stringValue == "asr" }?["state"]?.stringValue, "ok")
        XCTAssertEqual(rows.first { $0["id"]?.stringValue == "llm" }?["state"]?.stringValue, "fail")
        struct Down: Error {}
        let down = await LiveReadiness.checkASR(live, env: ["CALL_MEMORY_ASR_URL": "ws://h:8011"], health: { _ in throw Down() })
        XCTAssertEqual(down["state"]?.stringValue, "fail")
        let busy = await LiveReadiness.checkASR(live, env: ["CALL_MEMORY_ASR_URL": "ws://h:8011"], health: { _ in Data(#"{"busy": true}"#.utf8) })
        XCTAssertEqual(busy["state"]?.stringValue, "warn")
    }
}

final class RecordingTransport: ResponsesHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [(Int, String)]
    private var seen: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { seen } }

    init(_ responses: [(Int, String)]) { self.responses = responses }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body) = lock.withLock { () -> (Int, String) in
            seen.append(request)
            return responses.isEmpty ? (500, "") : responses.removeFirst()
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

final class LiveChatClientTests: XCTestCase {
    func testRequestShapeAndReply() async throws {
        let transport = RecordingTransport([(200, #"{"choices": [{"message": {"content": "hi"}}]}"#)])
        let client = ChatClient(LLMConfig(), transport: transport, env: ["INCEPTION_API_KEY": "test-key"], sleep: { _ in })
        let reply = try await client.complete(messages: [["role": "user", "content": "x"]], tools: LiveContextTools.definitions)
        XCTAssertEqual(reply["content"]?.stringValue, "hi")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.inceptionlabs.ai/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let body = try XCTUnwrap(JSONValue.parse(request.httpBody ?? Data()))
        XCTAssertEqual(body["model"]?.stringValue, "mercury-2")
        XCTAssertEqual(body["reasoning_effort"]?.stringValue, "low")
        XCTAssertEqual(body["max_tokens"]?.intValue, 4000)
        XCTAssertEqual(body["tools"]?.arrayValue?.count, 2)
        XCTAssertEqual(client.label, "mercury:mercury-2")
    }

    func testRetriesOnceOnRateLimitThenReportsStatus() async throws {
        let ok = RecordingTransport([(429, ""), (200, #"{"choices": [{"message": {"content": "ok"}}]}"#)])
        let reply = try await ChatClient(LLMConfig(), transport: ok, env: ["INCEPTION_API_KEY": "k"], sleep: { _ in }).complete(messages: [])
        XCTAssertEqual(reply["content"]?.stringValue, "ok")
        XCTAssertEqual(ok.requests.count, 2)
        let bad = RecordingTransport([(401, ""), (401, "")])
        do {
            _ = try await ChatClient(LLMConfig(), transport: bad, env: ["INCEPTION_API_KEY": "k"], sleep: { _ in }).complete(messages: [])
            XCTFail("expected failure")
        } catch { XCTAssertEqual((error as? LLMError)?.message, "model request failed (HTTP 401)") }
        XCTAssertEqual(bad.requests.count, 1)   // not retried
    }

    func testMissingKeyFailsBeforeAnyRequest() async {
        let transport = RecordingTransport([])
        do {
            _ = try await ChatClient(LLMConfig(), transport: transport, env: [:]).complete(messages: [])
            XCTFail("expected failure")
        } catch { XCTAssertTrue(error is MissingKey) }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testCloudASRPostsWavAsMultipart() async throws {
        let transport = RecordingTransport([(200, #"{"text": "from the cloud"}"#)])
        let asr = OpenAIASR(CloudASRConfig(), language: "en-US", transport: transport, env: ["OPENAI_API_KEY": "k"])
        let text = try await asr.transcribe(pcm: Data(count: 640), onPartial: nil)
        XCTAssertEqual(text, "from the cloud")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") ?? false)
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"model\"") && body.contains("gpt-transcribe") && body.contains("name=\"language\"") && body.contains("RIFF"))
    }

    func testSHA256KnownVectors() {
        XCTAssertEqual(SHA256Digest.hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256Digest.hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        var digest = SHA256Digest()
        digest.update(Data(repeating: 0x61, count: 1_000_000 / 2)); digest.update(Data(repeating: 0x61, count: 1_000_000 / 2))
        XCTAssertEqual(digest.finalize(), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }
}

final class LiveDemoTests: XCTestCase {
    func testSampleCallPlaysAndRecapsByProgress() async throws {
        let demo = DemoSession(speed: 60)
        let events = demo.subscribe()
        try demo.start()
        var kinds = Set<String>()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, demo.status != "stopped" {
            if let event = events.get(timeout: 0.2), let kind = event["type"]?.stringValue { kinds.insert(kind) }
        }
        XCTAssertEqual(demo.status, "stopped")
        XCTAssertTrue(kinds.isSuperset(of: ["entry", "partial", "context", "status", "level"]))
        let state = demo.state()
        XCTAssertEqual(state["sample"]?.boolValue, true)
        XCTAssertEqual(state["entries"]?.arrayValue?.count, 9)
        XCTAssertEqual(state["provenance"], ["heard": "sample", "notes": "sample", "notes_host": ""])
        let context = try XCTUnwrap(state["context"])
        let decisions = context["decisions"]?.arrayValue ?? []
        XCTAssertEqual(decisions.count, 2)
        XCTAssertEqual(decisions[0]["evidence"]?.arrayValue?.first?["entry"]?.intValue, 3)
        XCTAssertEqual(decisions[1]["proposed"]?.boolValue, true)
        XCTAssertEqual(decisions[0]["proposed"]?.boolValue, false)
        let recap = try await demo.recap(minutes: 5)
        XCTAssertEqual(recap["model"]?.stringValue, "sample")
        XCTAssertEqual(recap["entries"]?.intValue, 9)
        XCTAssertEqual(recap["asks_of_me"]?.arrayValue?.count, 2)
        XCTAssertEqual(recap["asks_of_me"]?.arrayValue?.first, ["text": "Can you take the support queue on Tuesday?", "entry": 9])
        XCTAssertEqual(recap["from_s"]?.doubleValue, 1)
        XCTAssertEqual(recap["to_s"]?.doubleValue, 48)
    }
}
