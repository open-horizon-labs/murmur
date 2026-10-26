import Foundation

/// What the web layer (or an app) needs from a call, real or sample.
public protocol LiveCallControlling: AnyObject, Sendable {
    var status: String { get }
    var isSample: Bool { get }
    func start() throws
    func stop() async
    func state() -> JSONValue
    func subscribe() -> EventQueue
    func unsubscribe(_ queue: EventQueue)
    func recap(minutes: Int) async throws -> JSONValue
}

public struct LiveSessionError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// One live call: channels -> endpointing -> ASR -> transcript -> Context, plus local audio.
///
/// Audio is written to disk first (raw PCM), so a crash never loses the call; at stop it is staged as a normal
/// recording and the shared-folder worker produces the diarized transcript later.
public final class LiveSession: LiveCallControlling, @unchecked Sendable {
    public static let speakers = ["mic": "me", "system": "them"]

    public let id: String
    public let root: URL
    public let directory: URL
    public let transcript = LiveTranscript()
    public let startedAt: String
    public let isSample = false

    private let asr: any LiveASR
    private let agent: any LiveContextAgent
    private let channels: [String]
    private let keepAudio: Bool
    private let sourceFactory: PCMSourceFactory
    private let minInterval: Double
    public let provenance: [String: String]
    private let lock = NSLock()
    private let saveLock = NSLock()
    private var _status = "idle"
    private var _context: JSONValue?
    private var _contextError: String?
    private var _partials: [String: String] = [:]
    private var _notices: [String] = []
    private var subscribers: [ObjectIdentifier: EventQueue] = [:]
    private var sources: [any PCMSource] = []
    private let channelGroup = DispatchGroup()
    private var finishers: [Task<Void, Never>] = []
    private var mixer: Mixer
    private var pcmHandle: FileHandle?
    private var updater: ContextUpdater?

    public init(
        root: URL,
        asr: any LiveASR,
        agent: any LiveContextAgent,
        channels: [String] = ["mic"],
        keepAudio: Bool = true,
        sourceFactory: @escaping PCMSourceFactory = { try ProcessPCMSource(kind: $0) },
        minInterval: Double = 3.0,
        provenance: [String: String] = [:]
    ) {
        self.provenance = provenance
        self.root = root
        self.id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        self.directory = root.appendingPathComponent("live").appendingPathComponent(id)
        self.asr = asr
        self.agent = agent
        self.channels = channels
        self.keepAudio = keepAudio
        self.sourceFactory = sourceFactory
        self.minInterval = minInterval
        self.startedAt = LiveStaging.isoTimestamp()
        self.mixer = Mixer(channels)
    }

    // MARK: events and state

    public var status: String { lock.lock(); defer { lock.unlock() }; return _status }
    private func setStatus(_ value: String) { lock.withLock { _status = value } }
    public var context: JSONValue? { lock.lock(); defer { lock.unlock() }; return _context }
    public var contextError: String? { lock.lock(); defer { lock.unlock() }; return _contextError }
    public var notices: [String] { lock.lock(); defer { lock.unlock() }; return _notices }

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
        let value = JSONValue.object(event)
        for queue in queues { queue.put(value) }
    }

    public func state() -> JSONValue {
        lock.lock(); defer { lock.unlock() }
        return ["id": .string(id), "provenance": .object(provenance.mapValues { .string($0) }),
                "status": .string(_status), "started_at": .string(startedAt),
                "entries": .array(transcript.snapshot().map(\.json)),
                "partials": .object(_partials.mapValues { .string($0) }),
                "context": _context ?? .null, "context_error": _contextError.map { .string($0) } ?? .null,
                "notices": JSONValue(_notices)]
    }

    private func notice(_ text: String) {
        lock.lock()
        let isNew = !_notices.contains(text)
        if isNew { _notices.append(text) }
        lock.unlock()
        if isNew { emit("notice", ["text": .string(text)]) }
    }

    private func onContext(_ context: JSONValue?, _ error: String?) {
        lock.withLock { _context = context; _contextError = error }
        emit("context", ["context": context ?? .null, "error": error.map { .string($0) } ?? .null])
        save()
    }

    /// What was discussed in the last `minutes` of the call (call time, not wall time).
    public func recap(minutes: Int = 5) async throws -> JSONValue {
        try await agent.recap(snapshot: transcript.snapshot(), minutes: minutes)
    }

    // MARK: lifecycle

    public func start() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try LiveStaging.writeJSON(["id": .string(id), "started_at": .string(startedAt), "status": "recording"],
                                  to: directory.appendingPathComponent("session.json"))
        if keepAudio {
            let path = directory.appendingPathComponent("audio.pcm")
            _ = FileManager.default.createFile(atPath: path.path, contents: nil)
            pcmHandle = try FileHandle(forWritingTo: path)
        }
        updater = ContextUpdater(transcript: transcript, agent: agent, minInterval: minInterval) { [weak self] context, error in
            self?.onContext(context, error)
        }
        setStatus("listening")
        for kind in channels {
            let source: any PCMSource
            do {
                source = try sourceFactory(kind)
                try source.start()
            } catch {
                notice("Could not capture \(kind) audio (\(type(of: error))); continuing without it.")
                continue
            }
            sources.append(source)
            channelGroup.enter()
            let group = channelGroup
            let thread = Thread { [self] in
                runChannel(kind, source)
                group.leave()
            }
            thread.start()
        }
        if sources.isEmpty {
            setStatus("stopped")
            throw LiveSessionError("No audio source could be started.")
        }
        emit("status", ["status": .string(status)])
    }

    private func runChannel(_ kind: String, _ source: any PCMSource) {
        let speaker = Self.speakers[kind] ?? kind
        var endpointer = Endpointer()
        var stream: (any LiveASRStream)?
        var begin = 0.0
        var lastLevel = Date.distantPast

        func handle(_ events: [EndpointEvent]) {
            for event in events {
                switch event {
                case .start(let offset):
                    begin = offset
                    stream = asr.open { [weak self] text in self?.partial(speaker, text) }
                case .audio(let data):
                    stream?.send(data)
                case .end(let offset):
                    guard let done = stream else { continue }
                    stream = nil
                    let started = begin
                    track(Task { [self] in await finish(done, speaker: speaker, begin: started, end: offset) })
                case .cancel:
                    guard let done = stream else { continue }
                    stream = nil
                    done.close()
                }
            }
        }

        while let chunk = source.nextChunk() {
            let now = Date()
            if now.timeIntervalSince(lastLevel) >= 0.2 {      // about five meter updates a second
                lastLevel = now
                emit("level", ["channel": .string(speaker), "level": .number(min(1.0, LiveAudio.rms(chunk.suffix(640)) / 6000))])
            }
            record(kind, chunk)
            handle(endpointer.feed(chunk))
        }
        handle(endpointer.flush())
    }

    private func track(_ task: Task<Void, Never>) {
        lock.withLock { finishers.append(task) }
    }

    private func finish(_ stream: any LiveASRStream, speaker: String, begin: Double, end: Double) async {
        let result: (text: String, backend: String)
        do {
            result = try await stream.finish()
        } catch {
            notice("Could not transcribe a passage from \(speaker): \(error.localizedDescription)")
            clearPartial(speaker)
            return
        }
        clearPartial(speaker)
        if asr.isDegraded { notice("Homelab ASR unavailable; using the cloud fallback for some speech.") }
        if !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let entry = transcript.add(speaker: speaker, start: begin, end: end, text: result.text, backend: result.backend)
            emit("entry", ["entry": entry.json])
            updater?.notify()
            save()
        }
    }

    private func partial(_ speaker: String, _ text: String) {
        lock.withLock { _partials[speaker] = text }
        emit("partial", ["speaker": .string(speaker), "text": .string(text)])
    }

    private func clearPartial(_ speaker: String) {
        lock.withLock { _partials[speaker] = nil }
    }

    private func record(_ kind: String, _ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        guard let handle = pcmHandle else { return }
        mixer.add(kind, chunk)
        let data = mixer.drain()
        if !data.isEmpty { try? handle.write(contentsOf: data) }
    }

    private func beginStopping() -> ([any PCMSource], DispatchGroup)? {
        lock.withLock {
            if _status == "stopped" || _status == "stopping" { return nil }
            _status = "stopping"
            return (sources, channelGroup)
        }
    }

    private func closeRecording() {
        lock.withLock {
            if let handle = pcmHandle {
                try? handle.write(contentsOf: mixer.drain(final: true))
                try? handle.close()
                pcmHandle = nil
            }
        }
    }

    public func stop() async {
        guard let (sources, group) = beginStopping() else { return }
        emit("status", ["status": "stopping"])
        for source in sources { source.stop() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                _ = group.wait(timeout: .now() + 10)
                continuation.resume()
            }
        }
        let tasks = lock.withLock { finishers }
        for task in tasks { await task.value }
        await updater?.finish()
        closeRecording()
        setStatus("stopped")
        save(final: true)
        emit("status", ["status": "stopped"])
    }

    // MARK: persistence

    private func save(final: Bool = false) {
        saveLock.lock(); defer { saveLock.unlock() }
        let context = lock.withLock { _context }
        let entries = transcript.snapshot()
        var data: [String: JSONValue] = ["id": .string(id), "started_at": .string(startedAt),
                                         "status": .string(final ? "complete" : "recording"),
                                         "entries": .array(entries.map(\.json)), "context": context ?? .null]
        try? LiveStaging.writeJSON(.object(data), to: directory.appendingPathComponent("session.json"))
        guard final else { return }
        try? Data((LiveText.render(entries) + "\n").utf8).write(to: directory.appendingPathComponent("transcript.txt"))
        if let recording = try? LiveStaging.stageRecording(root: root, sessionID: id, pcmURL: directory.appendingPathComponent("audio.pcm"),
                                                           startedAt: startedAt, keepAudio: keepAudio),
           let key = recording["object_key"] {
            data["recording"] = key
            try? LiveStaging.writeJSON(.object(data), to: directory.appendingPathComponent("session.json"))
        }
    }
}
