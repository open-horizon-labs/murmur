import Foundation

/// Owns a listening session across a bounded number of fresh transport connections.
/// Audio received during recovery is discarded, never replayed into another session.
actor RecoveringTranscriptionClient: RealtimeTranscribing {
    private struct Configuration: Sendable {
        let key: String
        let model: TranscriptionModel
        let context: String
    }
    private let factory: @Sendable () -> any RealtimeTranscribing
    private let delays: [Duration]
    private var epoch: UUID?
    private var connectionID: UUID?
    private var client: (any RealtimeTranscribing)?
    private var configuration: Configuration?
    private var handler: (@Sendable (TranscriptionEvent) -> Void)?
    private var recovery: Task<Void, Never>?
    private var recoveryID: UUID?
    private var eventTask: Task<Void, Never>?
    private var ready = false
    private var pending: [TranscriptionEvent] = []
    private var attempts = 0

    init(delays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)],
         factory: @escaping @Sendable () -> any RealtimeTranscribing = { RealtimeTranscriptionClient() }) {
        self.delays = delays
        self.factory = factory
    }

    func connect(apiKey: String, model: TranscriptionModel, context: String,
                 eventHandler: @escaping @Sendable (TranscriptionEvent) -> Void) async throws {
        let previous = retire()
        let token = UUID()
        epoch = token
        configuration = Configuration(key: apiKey, model: model, context: context)
        handler = eventHandler
        attempts = 0
        await previous?.disconnect()
        guard epoch == token else { throw CancellationError() }
        do { try await open(token) }
        catch {
            if epoch == token { let old = retire(); await old?.disconnect() }
            throw error
        }
    }

    func send(audioPCM16 data: Data) async {
        guard ready, let client else { return }
        await client.send(audioPCM16: data)
    }

    func disconnect() async {
        let old = retire()
        await old?.disconnect()
    }

    private func retire() -> (any RealtimeTranscribing)? {
        let old = client
        epoch = nil; connectionID = nil; client = nil; ready = false
        configuration = nil; handler = nil; pending = []
        recovery?.cancel(); recovery = nil; recoveryID = nil
        eventTask?.cancel(); eventTask = nil
        return old
    }

    private func open(_ token: UUID) async throws {
        guard epoch == token, let configuration else { throw CancellationError() }
        let id = UUID(), next = factory()
        connectionID = id; client = next; ready = false; pending = []
        let (events, continuation) = AsyncStream<TranscriptionEvent>.makeStream(bufferingPolicy: .bufferingOldest(128))
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.receive(event, token: token, connection: id)
            }
        }
        do {
            try await next.connect(apiKey: configuration.key, model: configuration.model, context: configuration.context) { [weak self] event in
                if case .dropped = continuation.yield(event) {
                    continuation.finish()
                    Task { await self?.receive(.failed("Transcription events could not be processed safely. Resume to reconnect."), token: token, connection: id) }
                }
            }
            guard epoch == token, connectionID == id, !Task.isCancelled else { throw CancellationError() }
            // Failures racing the handshake must not be mistaken for recovery.
            for event in pending {
                if case .transportLost = event { throw URLError(.networkConnectionLost) }
                if case .failed(let message) = event { throw RealtimeError.sessionRejected(message) }
            }
            ready = true
            let events = pending; pending = []
            for event in events { receive(event, token: token, connection: id) }
        } catch {
            if connectionID == id { client = nil; connectionID = nil; ready = false; pending = []; eventTask?.cancel(); eventTask = nil }
            await next.disconnect()
            throw error
        }
    }

    private func receive(_ event: TranscriptionEvent, token: UUID, connection: UUID) {
        guard epoch == token, connectionID == connection else { return }
        guard ready else {
            if pending.contains(where: { event in
                switch event { case .failed, .transportLost: true; default: false }
            }) { return }
            if pending.count < 128 { pending.append(event) }
            else { pending = [.failed("Transcription sent too many events before setup completed. Resume to reconnect.")] }
            return
        }
        switch event {
        case .transportLost:
            let old = client
            ready = false; connectionID = nil; client = nil
            eventTask?.cancel(); eventTask = nil
            handler?(.recovering(attempt: min(attempts + 1, delays.count), maximum: delays.count))
            let recoveryID = UUID()
            self.recoveryID = recoveryID
            recovery = Task { [weak self] in
                await old?.disconnect()
                await self?.recover(token, recoveryID: recoveryID)
            }
        case .failed(let message):
            handler?(.failed(message))
            let old = retire()
            Task { await old?.disconnect() }
        case .partial(let id, let delta):
            handler?(.partial(itemID: "\(connection):\(id)", delta: delta))
        case .completed(let id, let text):
            handler?(.completed(itemID: "\(connection):\(id)", text: text))
        case .committed(let id, let previous):
            handler?(.committed(itemID: "\(connection):\(id)", previousItemID: previous.map { "\(connection):\($0)" }))
        case .recovering, .recovered: break // Only this owner emits recovery state.
        }
    }

    private func recover(_ token: UUID, recoveryID: UUID) async {
        while epoch == token, self.recoveryID == recoveryID, !Task.isCancelled, attempts < delays.count {
            let delay = delays[attempts]
            attempts += 1
            handler?(.recovering(attempt: attempts, maximum: delays.count))
            do {
                try await Task.sleep(for: delay)
                guard epoch == token, self.recoveryID == recoveryID, !Task.isCancelled else { return }
                try await open(token)
                guard epoch == token, self.recoveryID == recoveryID, !Task.isCancelled else { return }
                guard ready else { return }
                handler?(.recovered)
                recovery = nil; self.recoveryID = nil
                return
            } catch {
                guard epoch == token, self.recoveryID == recoveryID, !Task.isCancelled else { return }
                if !RealtimeTransportFailure.isRecoverable(error) {
                    handler?(.failed("Transcription could not reconnect. Check your API key and transcription settings, then Resume."))
                    let old = retire(); await old?.disconnect()
                    return
                }
            }
        }
        guard epoch == token, self.recoveryID == recoveryID, !Task.isCancelled else { return }
        handler?(.failed("Transcription disconnected and could not recover after \(delays.count) attempts. Check your connection, then Resume. Audio around the interruption may be missing."))
        let old = retire(); await old?.disconnect()
    }
}

enum RealtimeTransportFailure {
    static func isRecoverable(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain {
            return [Int(ENOTCONN), Int(ECONNRESET), Int(ECONNABORTED), Int(EPIPE), Int(ETIMEDOUT), Int(ENETDOWN), Int(ENETUNREACH), Int(EHOSTUNREACH)].contains(error.code)
        }
        guard error.domain == NSURLErrorDomain else { return false }
        return [URLError.networkConnectionLost, .notConnectedToInternet, .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains { $0.rawValue == error.code }
    }
}
