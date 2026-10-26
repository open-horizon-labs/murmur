import Foundation
import XCTest
@testable import MurmurCore

final class TranscriptionReliabilityTests: XCTestCase {
    func testSessionConfigurationUsesExplicitClientTurnDetectionForBothModels() throws {
        for model in TranscriptionModel.allCases {
            let update = RealtimeSessionConfiguration.update(model: model, context: "meeting terms")
            let session = try XCTUnwrap(update["session"] as? [String: Any])
            let audio = try XCTUnwrap(session["audio"] as? [String: Any])
            let input = try XCTUnwrap(audio["input"] as? [String: Any])
            let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
            XCTAssertEqual(transcription["model"] as? String, model.rawValue)
            XCTAssertTrue(input["turn_detection"] is NSNull)
            if model == .live {
                XCTAssertEqual(transcription["prompt"] as? String, "meeting terms")
                XCTAssertEqual(transcription["delay"] as? String, "low")
            } else {
                XCTAssertNil(transcription["prompt"])
                XCTAssertNil(transcription["delay"])
            }
        }
    }

    func testVADKeepsBoundedPreRollAndCommitsAfterTrailingSilence() {
        var detector = PCM16VoiceActivityDetector()
        let silence = pcm16(samples: 7_200, value: 0) // 300 ms
        let speech = pcm16(samples: 2_400, value: 2_000) // 100 ms

        XCTAssertTrue(detector.consume(silence).isEmpty)
        XCTAssertEqual(detector.consume(speech), [.append(silence), .append(speech)])
        XCTAssertEqual(detector.consume(silence), [.append(silence)])
        XCTAssertEqual(detector.consume(silence), [.append(silence), .commit])
        XCTAssertTrue(detector.consume(silence).isEmpty)
    }

    func testVADCommitsAtMaximumUtteranceDuration() {
        var configuration = PCM16VoiceActivityDetector.Configuration()
        configuration.preRollMilliseconds = 0
        configuration.trailingSilenceMilliseconds = 10_000
        configuration.maximumUtteranceMilliseconds = 200
        var detector = PCM16VoiceActivityDetector(configuration: configuration)
        let speech = pcm16(samples: 2_400, value: 1_500) // 100 ms

        XCTAssertEqual(detector.consume(speech), [.append(speech)])
        XCTAssertEqual(detector.consume(speech), [.append(speech), .commit])
    }

    func testTranscriptDecoderCarriesItemIdentityForDeltasAndFinals() throws {
        let partial = try XCTUnwrap(RealtimeTranscriptionEventDecoder.decode([
            "type": "conversation.item.input_audio_transcription.delta",
            "item_id": "item_1",
            "delta": "hello"
        ]))
        let final = try XCTUnwrap(RealtimeTranscriptionEventDecoder.decode([
            "type": "conversation.item.input_audio_transcription.completed",
            "item_id": "item_1",
            "transcript": "hello there"
        ]))
        XCTAssertEqual(partial, .partial(itemID: "item_1", delta: "hello"))
        XCTAssertEqual(final, .completed(itemID: "item_1", text: "hello there"))
        XCTAssertNil(RealtimeTranscriptionEventDecoder.decode([
            "type": "conversation.item.input_audio_transcription.delta",
            "delta": "missing item id"
        ]))
    }

    func testClientWaitsForSessionUpdatedAndSendsAppendBeforeCommit() async throws {
        let socket = FakeRealtimeWebSocket(acknowledgeSessionUpdate: true)
        let client = RealtimeTranscriptionClient(socketFactory: { _ in socket })
        try await client.connect(apiKey: "test-only", model: .live, context: "terms") { _ in }

        let speech = pcm16(samples: 2_400, value: 1_500)
        let silence = pcm16(samples: 14_400, value: 0)
        await client.send(audioPCM16: speech)
        await client.send(audioPCM16: silence)
        await socket.waitForSentCount(4)

        let messages = await socket.sentMessages()
        let events = try messages.map { text -> [String: Any] in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }
        XCTAssertEqual(events.map { $0["type"] as? String }, [
            "session.update",
            "input_audio_buffer.append",
            "input_audio_buffer.append",
            "input_audio_buffer.commit"
        ])
        await client.disconnect()
    }

    func testClientTimesOutIfSessionUpdatedIsNotAcknowledged() async {
        let socket = FakeRealtimeWebSocket(acknowledgeSessionUpdate: false)
        let client = RealtimeTranscriptionClient(
            readinessTimeout: .milliseconds(20),
            socketFactory: { _ in socket }
        )
        do {
            try await client.connect(apiKey: "test-only", model: .accurate, context: "") { _ in }
            XCTFail("Expected the unacknowledged session update to time out.")
        } catch let error as RealtimeError {
            XCTAssertEqual(error, .sessionUpdateTimedOut)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testOlderReconnectCannotReplaceNewConnectionAfterSlowSocketCancellation() async throws {
        let oldSocket = FakeRealtimeWebSocket(acknowledgeSessionUpdate: true, holdCancellation: true)
        let newSocket = FakeRealtimeWebSocket(acknowledgeSessionUpdate: true)
        let sockets = SocketSequence([oldSocket, newSocket])
        let client = RealtimeTranscriptionClient(socketFactory: { _ in sockets.next() })
        try await client.connect(apiKey: "test-only", model: .live, context: "first") { _ in }

        let staleReconnect = Task {
            try await client.connect(apiKey: "test-only", model: .live, context: "stale") { _ in }
        }
        await oldSocket.waitUntilCancelling()
        try await client.connect(apiKey: "test-only", model: .live, context: "current") { _ in }
        await oldSocket.releaseCancellation()
        do {
            try await staleReconnect.value
            XCTFail("The superseded connection must not replace the current connection")
        } catch let error as RealtimeError {
            XCTAssertEqual(error, .disconnected)
        }
        await client.send(audioPCM16: pcm16(samples: 2_400, value: 1_500))
        await client.send(audioPCM16: pcm16(samples: 14_400, value: 0))
        await newSocket.waitForSentCount(4)
        let sent = await newSocket.sentMessages()
        XCTAssertTrue(sent.first?.contains("current") == true)
        await client.disconnect()
    }

    func testConnectionUsesTranscriptionIntentWithoutASessionModel() async throws {
        for model in TranscriptionModel.allCases {
            let socket = FakeRealtimeWebSocket(acknowledgeSessionUpdate: true)
            let client = RealtimeTranscriptionClient(socketFactory: { request in
                let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
                XCTAssertEqual(components?.queryItems, [URLQueryItem(name: "intent", value: "transcription")])
                return socket
            })
            try await client.connect(apiKey: "test-only", model: model, context: "") { _ in }
            await client.disconnect()
        }
    }

    func testLiveTranscriptionHandshakeWithoutAudioWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["MURMUR_LIVE_TRANSCRIPTION_HANDSHAKE"] == "1" else {
            throw XCTSkip("Opt in to verify session setup only; no audio is captured or sent.")
        }
        guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty else {
            throw XCTSkip("No launch credential available.")
        }
        for model in TranscriptionModel.allCases {
            let client = RealtimeTranscriptionClient(readinessTimeout: .seconds(15))
            do {
                try await client.connect(apiKey: key, model: model, context: "A work meeting.") { _ in }
                await client.disconnect()
            } catch {
                await client.disconnect()
                throw error
            }
        }
    }

    private func pcm16(samples: Int, value: Int16) -> Data {
        var data = Data(count: samples * MemoryLayout<Int16>.size)
        data.withUnsafeMutableBytes { rawBuffer in
            let output = rawBuffer.bindMemory(to: Int16.self)
            for index in output.indices { output[index] = value }
        }
        return data
    }
}

private actor FakeRealtimeWebSocket: RealtimeWebSocket {
    private let acknowledgeSessionUpdate: Bool
    private var incoming: [String] = []
    private var receiver: CheckedContinuation<String, Error>?
    private var sent: [String] = []
    private var holdCancellation: Bool
    private var cancelStarted = false
    private var cancellation: CheckedContinuation<Void, Never>?
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []
    private var sentWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(acknowledgeSessionUpdate: Bool, holdCancellation: Bool = false) {
        self.acknowledgeSessionUpdate = acknowledgeSessionUpdate
        self.holdCancellation = holdCancellation
    }

    func resume() async {}

    func send(text: String) async throws {
        sent.append(text)
        resolveSentWaiters()
        guard acknowledgeSessionUpdate,
              let event = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              event["type"] as? String == "session.update" else { return }
        enqueue("{\"type\":\"session.updated\"}")
    }

    func receiveText() async throws -> String {
        if !incoming.isEmpty { return incoming.removeFirst() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }

    func cancel() async {
        cancelStarted = true
        cancelWaiters.forEach { $0.resume() }
        cancelWaiters.removeAll()
        if holdCancellation { await withCheckedContinuation { cancellation = $0 } }
        receiver?.resume(throwing: CancellationError())
        receiver = nil
    }

    func waitUntilCancelling() async {
        if cancelStarted { return }
        await withCheckedContinuation { cancelWaiters.append($0) }
    }

    func releaseCancellation() {
        holdCancellation = false
        cancellation?.resume()
        cancellation = nil
    }

    func sentMessages() -> [String] { sent }

    func waitForSentCount(_ count: Int) async {
        if sent.count >= count { return }
        await withCheckedContinuation { sentWaiters.append((count, $0)) }
    }

    private func enqueue(_ text: String) {
        if let receiver {
            self.receiver = nil
            receiver.resume(returning: text)
        } else {
            incoming.append(text)
        }
    }

    private func resolveSentWaiters() {
        let ready = sentWaiters.filter { sent.count >= $0.0 }
        sentWaiters.removeAll { sent.count >= $0.0 }
        for (_, continuation) in ready { continuation.resume() }
    }
}

private final class SocketSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [any RealtimeWebSocket]
    init(_ sockets: [any RealtimeWebSocket]) { self.sockets = sockets }
    func next() -> any RealtimeWebSocket { lock.withLock { sockets.removeFirst() } }
}
