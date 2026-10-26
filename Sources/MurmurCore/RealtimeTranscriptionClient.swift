import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

protocol RealtimeWebSocket: Sendable {
    func resume() async
    func send(text: String) async throws
    func receiveText() async throws -> String
    func cancel() async
}

private final class URLSessionRealtimeWebSocket: RealtimeWebSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) { self.task = task }
    func resume() async { task.resume() }
    func cancel() async { task.cancel(with: .normalClosure, reason: nil) }

    func send(text: String) async throws {
        try await task.send(.string(text))
    }

    func receiveText() async throws -> String {
        switch try await task.receive() {
        case .string(let text): text
        case .data(let data): String(decoding: data, as: UTF8.self)
        @unknown default: ""
        }
    }
}

actor RealtimeTranscriptionClient {
    private var socket: (any RealtimeWebSocket)?
    private var receiver: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var readinessTimeout: Task<Void, Never>?
    private var readinessContinuation: CheckedContinuation<Void, Error>?
    private var sessionIsReady = false
    private var generation: UUID?
    private var connectionRequest: UUID?
    private var eventHandler: (@Sendable (TranscriptionEvent) -> Void)?
    private var vad = PCM16VoiceActivityDetector()
    private var outbound: [RealtimeOutboundEvent] = []
    private var outboundByteCount = 0
    private let socketFactory: @Sendable (URLRequest) -> any RealtimeWebSocket
    private let readinessTimeoutDuration: Duration

    init(
        readinessTimeout: Duration = .seconds(8),
        socketFactory: @escaping @Sendable (URLRequest) -> any RealtimeWebSocket = {
            URLSessionRealtimeWebSocket(task: URLSession.shared.webSocketTask(with: $0))
        }
    ) {
        self.readinessTimeoutDuration = readinessTimeout
        self.socketFactory = socketFactory
    }

    func connect(
        apiKey: String,
        model: TranscriptionModel,
        context: String,
        eventHandler: @escaping @Sendable (TranscriptionEvent) -> Void
    ) async throws {
        let requestID = UUID()
        connectionRequest = requestID
        let previousSocket = detachConnection()
        await previousSocket?.cancel()
        guard connectionRequest == requestID else { throw RealtimeError.disconnected }
        guard let url = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription") else {
            throw RealtimeError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let activeGeneration = UUID()
        let socket = socketFactory(request)
        generation = activeGeneration
        self.socket = socket
        self.eventHandler = eventHandler
        self.sessionIsReady = false
        self.vad.reset()
        await socket.resume()
        guard connectionRequest == requestID, generation == activeGeneration else {
            await socket.cancel()
            throw RealtimeError.disconnected
        }
        receiver = Task { [weak self] in await self?.receiveLoop(generation: activeGeneration) }

        do {
            try await sendUpdateAndWait(model: model, context: context, generation: activeGeneration)
        } catch {
            if generation == activeGeneration { await disconnect() }
            throw error
        }
    }

    func send(audioPCM16 data: Data) async {
        guard socket != nil, !data.isEmpty else { return }
        for action in vad.consume(data) {
            switch action {
            case .append(let audio): enqueue(.append(audio))
            case .commit: enqueue(.commit)
            }
        }
    }

    func disconnect() async {
        connectionRequest = nil
        let previousSocket = detachConnection()
        await previousSocket?.cancel()
    }

    // Clear ownership before any await so old teardown cannot erase a new session.
    private func detachConnection() -> (any RealtimeWebSocket)? {
        let previousSocket = socket
        generation = nil
        readinessTimeout?.cancel()
        readinessTimeout = nil
        if let readinessContinuation {
            self.readinessContinuation = nil
            readinessContinuation.resume(throwing: RealtimeError.disconnected)
        }
        receiver?.cancel()
        receiver = nil
        sender?.cancel()
        sender = nil
        socket = nil
        eventHandler = nil
        outbound.removeAll(keepingCapacity: false)
        outboundByteCount = 0
        vad.reset()
        sessionIsReady = false
        return previousSocket
    }

    private func sendUpdateAndWait(
        model: TranscriptionModel,
        context: String,
        generation expectedGeneration: UUID
    ) async throws {
        guard generation == expectedGeneration else { throw RealtimeError.disconnected }
        if sessionIsReady { return }
        try await withCheckedThrowingContinuation { continuation in
            readinessContinuation = continuation
            let timeout = readinessTimeoutDuration
            readinessTimeout = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                await self?.readinessExpired(generation: expectedGeneration)
            }
            Task { [weak self] in
                await self?.sendSessionUpdate(model: model, context: context, generation: expectedGeneration)
            }
        }
    }

    private func sendSessionUpdate(
        model: TranscriptionModel,
        context: String,
        generation expectedGeneration: UUID
    ) async {
        guard generation == expectedGeneration else { return }
        do {
            try await sendJSON(RealtimeSessionConfiguration.update(model: model, context: context))
        } catch {
            failReadiness(generation: expectedGeneration, error: error)
        }
    }

    private func failReadiness(generation expectedGeneration: UUID, error: Error) {
        guard generation == expectedGeneration, let readinessContinuation else { return }
        self.readinessContinuation = nil
        readinessTimeout?.cancel()
        readinessTimeout = nil
        readinessContinuation.resume(throwing: error)
    }

    private func readinessExpired(generation expectedGeneration: UUID) {
        guard generation == expectedGeneration else { return }
        guard generation == expectedGeneration, let readinessContinuation else { return }
        self.readinessContinuation = nil
        readinessTimeout = nil
        readinessContinuation.resume(throwing: RealtimeError.sessionUpdateTimedOut)
    }

    private func markReady(generation expectedGeneration: UUID) {
        guard generation == expectedGeneration else { return }
        sessionIsReady = true
        readinessTimeout?.cancel()
        readinessTimeout = nil
        if let readinessContinuation {
            self.readinessContinuation = nil
            readinessContinuation.resume()
        }
    }

    private func enqueue(_ event: RealtimeOutboundEvent) {
        let size = event.byteCount
        guard outboundByteCount + size <= 2 * 1024 * 1024 else {
            eventHandler?(.failed(RealtimeError.sendQueueOverflow.localizedDescription))
            guard let expectedGeneration = generation else { return }
            Task { [weak self] in await self?.disconnect(ifCurrent: expectedGeneration) }
            return
        }
        outbound.append(event)
        outboundByteCount += size
        guard sender == nil else { return }
        guard let generation else { return }
        sender = Task { [weak self] in await self?.drainOutbound(generation: generation) }
    }

    private func drainOutbound(generation expectedGeneration: UUID) async {
        while !Task.isCancelled {
            guard generation == expectedGeneration else { return }
            guard socket != nil, !outbound.isEmpty else {
                sender = nil
                return
            }
            let event = outbound.removeFirst()
            outboundByteCount -= event.byteCount
            do {
                try await sendJSON(event.json)
            } catch {
                guard generation == expectedGeneration else { return }
                eventHandler?(RealtimeTransportFailure.isRecoverable(error) ? .transportLost : .failed("Transcription connection failed. Check your connection and API settings, then Resume."))
                await disconnect()
                return
            }
        }
        if generation == expectedGeneration { sender = nil }
    }

    private func disconnect(ifCurrent expectedGeneration: UUID) async {
        guard generation == expectedGeneration else { return }
        await disconnect()
    }

    private func sendJSON(_ value: [String: Any]) async throws {
        guard let socket else { throw RealtimeError.notConnected }
        let data = try JSONSerialization.data(withJSONObject: value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RealtimeError.encodingFailed
        }
        try await socket.send(text: text)
    }

    private func receiveLoop(generation expectedGeneration: UUID) async {
        guard let socket else { return }

        while !Task.isCancelled {
            do {
                let text = try await socket.receiveText()
                let data = Data(text.utf8)

                guard generation == expectedGeneration,
                    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let type = object["type"] as? String
                else { continue }

                switch type {
                case "session.updated":
                    markReady(generation: expectedGeneration)
                case "conversation.item.input_audio_transcription.delta":
                    if let event = RealtimeTranscriptionEventDecoder.decode(object) { eventHandler?(event) }
                case "conversation.item.input_audio_transcription.completed":
                    if let event = RealtimeTranscriptionEventDecoder.decode(object) { eventHandler?(event) }
                case "error":
                    let message = (object["error"] as? [String: Any])?["message"] as? String ?? "Realtime session failed"
                    if !sessionIsReady {
                        failReadiness(generation: expectedGeneration, error: RealtimeError.sessionRejected(message))
                    }
                    eventHandler?(.failed(message))
                default:
                    break
                }
            } catch {
                failReadiness(generation: expectedGeneration, error: error)
                if !Task.isCancelled, generation == expectedGeneration {
                    eventHandler?(RealtimeTransportFailure.isRecoverable(error) ? .transportLost : .failed("Transcription connection failed. Check your connection and API settings, then Resume."))
                }
                return
            }
        }
    }
}

enum RealtimeTranscriptionEventDecoder {
    static func decode(_ event: [String: Any]) -> TranscriptionEvent? {
        if event["type"] as? String == "input_audio_buffer.committed",
           let itemID = event["item_id"] as? String {
            return .committed(
                itemID: itemID,
                previousItemID: event["previous_item_id"] as? String
            )
        }
        guard let type = event["type"] as? String,
              let itemID = event["item_id"] as? String else { return nil }
        switch type {
        case "conversation.item.input_audio_transcription.delta":
            guard let delta = event["delta"] as? String else { return nil }
            return .partial(itemID: itemID, delta: delta)
        case "conversation.item.input_audio_transcription.completed":
            guard let transcript = event["transcript"] as? String else { return nil }
            return .completed(itemID: itemID, text: transcript)
        default:
            return nil
        }
    }
}

private enum RealtimeOutboundEvent {
    case append(Data)
    case commit

    var byteCount: Int {
        switch self {
        case .append(let data): data.count
        case .commit: 0
        }
    }

    var json: [String: Any] {
        switch self {
        case .append(let audio):
            ["type": "input_audio_buffer.append", "audio": audio.base64EncodedString()]
        case .commit:
            ["type": "input_audio_buffer.commit"]
        }
    }
}

enum RealtimeSessionConfiguration {
    static func update(model: TranscriptionModel, context: String) -> [String: Any] {
        var transcription: [String: Any] = ["model": model.rawValue]
        if model == .live {
            transcription["prompt"] = context
            transcription["delay"] = "low"
        }
        return [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "transcription": transcription,
                        "turn_detection": NSNull()
                    ]
                ]
            ]
        ]
    }
}

enum RealtimeError: LocalizedError, Equatable {
    case invalidURL
    case notConnected
    case encodingFailed
    case disconnected
    case sessionUpdateTimedOut
    case sessionRejected(String)
    case sendQueueOverflow

    var errorDescription: String? {
        switch self {
        case .invalidURL: "The Realtime endpoint URL is invalid."
        case .notConnected: "The Realtime session is not connected."
        case .encodingFailed: "A Realtime event could not be encoded."
        case .disconnected: "The Realtime session disconnected before it became ready."
        case .sessionUpdateTimedOut: "The Realtime session did not confirm its configuration in time."
        case .sessionRejected(let message): "The Realtime session rejected its configuration: \(message)"
        case .sendQueueOverflow: "Audio arrived faster than the Realtime connection could send it."
        }
    }
}
