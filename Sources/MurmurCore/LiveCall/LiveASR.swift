import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ASRError: Error, LocalizedError, Sendable, Equatable {
    case busy
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .busy: ""
        case .failed(let message): message
        }
    }
}

public typealias PartialHandler = @Sendable (String) -> Void

/// A single streaming transcription of one utterance on one backend.
public protocol BackendStream: AnyObject, Sendable {
    func send(_ pcm: Data) async throws
    func finish() async throws -> String
    func close() async
}

/// A transcription backend (homelab Nemotron, cloud). One utterance = one stream.
public protocol ASRBackend: Sendable {
    var name: String { get }
    func open(onPartial: PartialHandler?) async throws -> any BackendStream
    func transcribe(pcm: Data, onPartial: PartialHandler?) async throws -> String
}

/// What a call session uses: connects in the background so capture never waits on the network.
public protocol LiveASRStream: AnyObject, Sendable {
    func send(_ pcm: Data)
    func finish() async throws -> (text: String, backend: String)
    func close()
}

public protocol LiveASR: Sendable {
    func open(onPartial: PartialHandler?) -> any LiveASRStream
    /// True once audio had to go to the cloud fallback.
    var isDegraded: Bool { get }
}

public enum LiveWAV {
    /// 16 kHz mono s16le PCM wrapped in a canonical 44-byte WAV header.
    public static func header(dataBytes: Int) -> Data {
        var data = Data()
        func u32(_ value: Int) { var v = UInt32(truncatingIfNeeded: value).littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u16(_ value: Int) { var v = UInt16(truncatingIfNeeded: value).littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(LiveAudio.rate); u32(LiveAudio.rate * 2); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return data
    }

    public static func wav(_ pcm: Data) -> Data { header(dataBytes: pcm.count) + pcm }
}

/// Run `operation`, returning nil if it has not finished after `seconds`.
func withTimeout<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T? {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        defer { group.cancelAll() }
        return try await group.next() ?? nil
    }
}

// MARK: - Homelab (Nemotron streaming over WebSocket)

/// Minimal WebSocket surface the homelab protocol needs; tests substitute a fake.
public protocol ASRSocket: Sendable {
    func sendText(_ text: String) async throws
    func sendBinary(_ data: Data) async throws
    /// Next text message, or nil if the socket closed.
    func receiveText() async throws -> String?
    func close() async
}

public final class URLSessionASRSocket: ASRSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    public init(url: URL, openTimeout: Double = 3) {
        var request = URLRequest(url: url)
        request.timeoutInterval = openTimeout
        task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = 1 << 20
        task.resume()
    }

    public func sendText(_ text: String) async throws { try await task.send(.string(text)) }
    public func sendBinary(_ data: Data) async throws { try await task.send(.data(data)) }

    public func receiveText() async throws -> String? {
        while true {
            switch try await task.receive() {
            case .string(let text): return text
            case .data: continue
            @unknown default: continue
            }
        }
    }

    public func close() async { task.cancel(with: .normalClosure, reason: nil) }
}

/// Nemotron streaming service (inference/nemotron-asr in homelab-infra): start/ready, binary PCM16 16 kHz,
/// partial/end/final. A busy service answers with an error event (and closes with 1013).
public struct HomelabASR: ASRBackend {
    public let name = "homelab"
    public let url: URL
    public let language: String
    private let connect: @Sendable (URL) async throws -> any ASRSocket

    public init(
        url baseURL: String,
        language: String = "en-US",
        connect: (@Sendable (URL) async throws -> any ASRSocket)? = nil
    ) {
        self.url = URL(string: baseURL.trimmingTrailingSlashes + "/v1/audio/stream") ?? URL(string: "ws://invalid/v1/audio/stream")!
        self.language = language
        self.connect = connect ?? { URLSessionASRSocket(url: $0) }
    }

    public func open(onPartial: PartialHandler?) async throws -> any BackendStream {
        let socket: any ASRSocket
        do {
            socket = try await connect(url)
            let start: JSONValue = ["type": "start", "sample_rate": JSONValue(LiveAudio.rate), "format": "pcm_s16le", "language": .string(language)]
            try await socket.sendText(start.jsonText)
            try await Self.expectReady(socket)
            // The streaming decoder drops or garbles the opening words without lead-in audio. One second of
            // silence sent at once (not paced) fixed it and cut the first partial from about 4 s to under 1 s.
            try await socket.sendBinary(Data(count: LiveAudio.rate * 2))
        } catch ASRError.busy {
            throw ASRError.busy
        } catch let error as ASRError {
            throw error
        } catch {
            throw ASRError.failed("homelab ASR unreachable (\(type(of: error)))")
        }
        return HomelabStream(socket: socket, onPartial: onPartial)
    }

    public func transcribe(pcm: Data, onPartial: PartialHandler?) async throws -> String {
        let stream = try await open(onPartial: onPartial)
        do {
            var position = 0
            while position < pcm.count {
                let end = min(position + 3200, pcm.count)
                try await stream.send(pcm.subdata(in: (pcm.startIndex + position)..<(pcm.startIndex + end)))
                position = end
            }
        } catch {
            await stream.close()
            throw ASRError.failed("homelab ASR failed (\(type(of: error)))")
        }
        return try await stream.finish()
    }

    private static func expectReady(_ socket: any ASRSocket) async throws {
        let message = try await withTimeout(5) { try await socket.receiveText() }
        guard let text = message ?? nil, let event = JSONValue.parse(text) else {
            throw ASRError.failed("unexpected ASR handshake")
        }
        if event["type"]?.stringValue == "error" {
            let detail = event["error"]?.stringValue ?? ""
            if detail.lowercased().contains("busy") || event["retry_after"] != nil { throw ASRError.busy }
            throw ASRError.failed(detail)
        }
        if event["type"]?.stringValue != "ready" { throw ASRError.failed("unexpected ASR handshake") }
    }
}

private final class HomelabStream: BackendStream, @unchecked Sendable {
    private let socket: any ASRSocket
    private let lock = NSLock()
    private var final: String?
    private var failure: String?
    private var reader: Task<Void, Never>?

    init(socket: any ASRSocket, onPartial: PartialHandler?) {
        self.socket = socket
        reader = Task { [weak self] in await self?.read(onPartial) }
    }

    private func read(_ onPartial: PartialHandler?) async {
        do {
            while let message = try await socket.receiveText() {
                guard let event = JSONValue.parse(message) else { continue }
                switch event["type"]?.stringValue {
                case "partial": onPartial?(event["text"]?.stringValue ?? "")
                case "final":
                    lock.withLock { final = event["text"]?.stringValue ?? "" }
                    return
                case "error":
                    lock.withLock { failure = event["error"]?.stringValue ?? "error" }
                    return
                default: break
                }
            }
        } catch {
            lock.withLock { failure = "\(type(of: error))" }
        }
    }

    func send(_ pcm: Data) async throws { try await socket.sendBinary(pcm) }

    func finish() async throws -> String {
        let reader = self.reader
        do {
            try await socket.sendText(JSONValue.object(["type": "end"]).jsonText)
            let completed = try await withTimeout(25) { await reader?.value; return true }
            if completed == nil { throw ASRError.failed("timed out waiting for the final transcript") }
            let (final, failure) = lock.withLock { (self.final, self.failure) }
            guard let final else { throw ASRError.failed(failure ?? "stream ended without a final transcript") }
            await close()
            return final
        } catch {
            await close()
            throw error
        }
    }

    func close() async {
        reader?.cancel()
        await socket.close()
    }
}

// MARK: - Cloud (OpenAI-compatible transcription)

public struct CloudASRConfig: Sendable, Equatable {
    public var baseURL = "https://api.openai.com/v1"
    public var model = "gpt-transcribe"
    public var keyEnv = "OPENAI_API_KEY"
    public var keyCommand: [String] = []
    public init() {}
}

/// Cloud backend: one request per finished utterance (no partials).
public struct OpenAIASR: ASRBackend {
    public let name = "openai"
    private let config: CloudASRConfig
    private let language: String
    private let transport: any ResponsesHTTPTransport
    private let env: [String: String]?

    public init(_ config: CloudASRConfig, language: String = "en-US", transport: any ResponsesHTTPTransport = URLSessionResponsesTransport(), env: [String: String]? = nil) {
        self.config = config
        self.language = String(language.split(separator: "-").first ?? "en")
        self.transport = transport
        self.env = env
    }

    public func open(onPartial: PartialHandler?) async throws -> any BackendStream {
        BufferedStream(backend: self)
    }

    public func transcribe(pcm: Data, onPartial: PartialHandler?) async throws -> String {
        let key = try LiveKeys.resolve(keyEnv: config.keyEnv, keyCommand: config.keyCommand, env: env)
        let boundary = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var body = Data()
        for (name, value) in [("model", config.model), ("language", language)] {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(LiveWAV.wav(pcm))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        guard let url = URL(string: config.baseURL.trimmingTrailingSlashes + "/audio/transcriptions") else {
            throw ASRError.failed("cloud ASR failed (invalid base URL)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        do {
            let (data, response) = try await transport.data(for: request)
            guard (200..<300).contains(response.statusCode), let json = JSONValue.parse(data) else {
                throw ASRError.failed("cloud ASR failed (HTTP \(response.statusCode))")
            }
            return json["text"]?.stringValue ?? ""
        } catch let error as ASRError {
            throw error
        } catch {
            throw ASRError.failed("cloud ASR failed (\(type(of: error)))")
        }
    }
}

private final class BufferedStream: BackendStream, @unchecked Sendable {
    private let backend: OpenAIASR
    private let lock = NSLock()
    private var pcm = Data()
    init(backend: OpenAIASR) { self.backend = backend }
    func send(_ chunk: Data) async throws { lock.withLock { pcm.append(chunk) } }
    func finish() async throws -> String {
        let data = lock.withLock { pcm }
        return try await backend.transcribe(pcm: data, onPartial: nil)
    }
    func close() async {}
}

// MARK: - Resilient (buffered replay, optional cloud fallback)

/// Primary backend with buffered replay. If the primary is busy or drops mid-utterance, the buffered audio is
/// replayed (primary a few times, then the cloud fallback if allowed). Audio is never lost to a failed stream.
public final class ResilientASR: LiveASR, @unchecked Sendable {
    let primary: any ASRBackend
    let fallback: (any ASRBackend)?
    private let retries: Int
    private let delay: Double
    private let sleep: @Sendable (Double) async -> Void
    private let lock = NSLock()
    private var degraded = false

    public init(
        primary: any ASRBackend,
        fallback: (any ASRBackend)? = nil,
        retries: Int = 3,
        delay: Double = 1.0,
        sleep: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) {
        self.primary = primary; self.fallback = fallback
        self.retries = retries; self.delay = delay; self.sleep = sleep
    }

    public var isDegraded: Bool { lock.lock(); defer { lock.unlock() }; return degraded }

    public func open(onPartial: PartialHandler?) -> any LiveASRStream {
        ResilientStream(owner: self, onPartial: onPartial)
    }

    /// (text, backend name). Throws ASRError if nothing worked.
    public func replay(_ pcm: Data, onPartial: PartialHandler? = nil) async throws -> (text: String, backend: String) {
        var last: ASRError?
        for _ in 0..<max(retries, 0) {
            do {
                return (try await primary.transcribe(pcm: pcm, onPartial: onPartial), primary.name)
            } catch let error as ASRError {
                last = error
                await sleep(delay)
            }
        }
        if let fallback {
            lock.withLock { degraded = true }
            return (try await fallback.transcribe(pcm: pcm, onPartial: nil), fallback.name)
        }
        let message = last?.localizedDescription ?? ""
        throw ASRError.failed(message.isEmpty ? "transcription unavailable" : message)
    }
}

private final class ResilientStream: LiveASRStream, @unchecked Sendable {
    private let owner: ResilientASR
    private let lock = NSLock()
    private var pcm = Data()
    private var inner: (any BackendStream)?
    private var failed = false
    private var closed = false
    private let continuation: AsyncStream<Data>.Continuation
    private var pump: Task<Void, Never>?

    init(owner: ResilientASR, onPartial: PartialHandler?) {
        self.owner = owner
        let (chunks, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        pump = Task { [weak self] in
            guard let self else { return }
            let stream: any BackendStream
            do {
                stream = try await owner.primary.open(onPartial: onPartial)
            } catch {
                self.markFailed()
                for await _ in chunks {}
                return
            }
            self.setInner(stream)
            for await chunk in chunks {
                if self.hasFailed { continue }
                do { try await stream.send(chunk) } catch { self.markFailed() }
            }
            if self.wasClosed { await stream.close() }
        }
    }

    private var hasFailed: Bool { lock.lock(); defer { lock.unlock() }; return failed }
    private var wasClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
    private func markFailed() { lock.withLock { failed = true } }
    private func setInner(_ stream: any BackendStream) { lock.withLock { inner = stream } }

    func send(_ chunk: Data) {
        lock.withLock { pcm.append(chunk) }
        continuation.yield(chunk)
    }

    func finish() async throws -> (text: String, backend: String) {
        continuation.finish()
        await pump?.value
        let (inner, failed, buffered) = lock.withLock { (self.inner, self.failed, pcm) }
        if let inner, !failed {
            do { return (try await inner.finish(), owner.primary.name) } catch is ASRError {}
        } else if let inner {
            await inner.close()
        }
        return try await owner.replay(buffered, onPartial: nil)
    }

    func close() {
        continuation.finish()
        lock.withLock { closed = true; let inner = self.inner }
        if let inner { Task { await inner.close() } }
    }
}
