import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Live-call audio: 16 kHz mono signed 16-bit little-endian PCM.
public enum LiveAudio {
    public static let rate = 16_000
    public static let frameSamples = 320           // 20 ms
    public static let frameBytes = frameSamples * 2

    public static func rms(_ frame: Data) -> Double {
        let count = frame.count / 2
        guard count > 0 else { return 0 }
        var sum = 0.0
        frame.withUnsafeBytes { raw in
            for index in 0..<count {
                let sample = Int16(bitPattern: raw.loadUnaligned(fromByteOffset: index * 2, as: UInt16.self).littleEndian)
                sum += Double(sample) * Double(sample)
            }
        }
        return (sum / Double(count)).squareRoot()
    }
}

public enum EndpointEvent: Equatable, Sendable {
    case start(Double)
    case audio(Data)
    case end(Double)
    case cancel(Double)
}

/// Turns a PCM stream into utterance events for a streaming recognizer.
///
/// An utterance is cut at `maxSeconds` so it fits the recognizer's per-stream limit; speech that continues
/// starts a new utterance immediately. Utterances with less than `minMs` of voiced audio are cancelled.
public struct Endpointer: Sendable {
    private let startFrames: Int
    private let endFrames: Int
    private let maxFrames: Int
    private let minFrames: Int
    private let prerollCapacity: Int
    private let floor: Double
    private var noise = 100.0
    private var preroll: [Data] = []
    private var pending = Data()
    private var index = 0
    private var speaking = false
    private var voicedRun = 0
    private var silence = 0
    private var voiced = 0
    private var length = 0

    public init(startFrames: Int = 4, endMs: Int = 700, prerollMs: Int = 300, maxSeconds: Double = 25, minMs: Int = 300, floor: Double = 250.0) {
        self.startFrames = startFrames
        self.endFrames = endMs / 20
        self.prerollCapacity = prerollMs / 20 + startFrames
        self.maxFrames = Int(maxSeconds * 1000 / 20)
        self.minFrames = minMs / 20
        self.floor = floor
    }

    private mutating func isVoiced(_ level: Double) -> Bool {
        let threshold = max(floor, noise * 3)
        if level <= threshold && !speaking {
            noise = 0.95 * noise + 0.05 * level
        }
        return level > threshold
    }

    public mutating func feed(_ pcm: Data) -> [EndpointEvent] {
        var events: [EndpointEvent] = []
        pending.append(pcm)
        let data = pending
        let usable = data.count / LiveAudio.frameBytes * LiveAudio.frameBytes
        pending = Data(data.dropFirst(usable))
        var position = 0
        while position < usable {
            let start = data.startIndex + position
            events += frame(Data(data[start..<(start + LiveAudio.frameBytes)]))
            position += LiveAudio.frameBytes
        }
        return events
    }

    private mutating func appendPreroll(_ frame: Data) {
        preroll.append(frame)
        if preroll.count > prerollCapacity { preroll.removeFirst(preroll.count - prerollCapacity) }
    }

    private mutating func frame(_ frame: Data) -> [EndpointEvent] {
        var events: [EndpointEvent] = []
        let offset = Double(index) * 0.02
        index += 1
        let isVoicedFrame = isVoiced(LiveAudio.rms(frame))
        if !speaking {
            appendPreroll(frame)
            voicedRun = isVoicedFrame ? voicedRun + 1 : 0
            if voicedRun >= startFrames {
                speaking = true
                voiced = voicedRun
                length = preroll.count
                silence = 0
                events.append(.start(max(0.0, offset - Double(length - 1) * 0.02)))
                events += preroll.map { .audio($0) }
                preroll.removeAll()
            }
            return events
        }
        events.append(.audio(frame))
        length += 1
        if isVoicedFrame {
            voiced += 1
            silence = 0
        } else {
            silence += 1
        }
        if silence >= endFrames || length >= maxFrames {
            let cutInSpeech = silence < endFrames && isVoicedFrame
            events.append(close(offset + 0.02))
            if cutInSpeech {   // keep listening: the next utterance starts at once
                speaking = true
                voiced = 1
                length = 0
                silence = 0
                events.append(.start(offset + 0.02))
            }
        }
        return events
    }

    private mutating func close(_ offset: Double) -> EndpointEvent {
        let isUtterance = voiced >= minFrames
        speaking = false
        voicedRun = 0
        preroll.removeAll()
        return isUtterance ? .end(offset) : .cancel(offset)
    }

    /// End of capture: close any open utterance.
    public mutating func flush() -> [EndpointEvent] {
        speaking ? [close(Double(index) * 0.02)] : []
    }
}

/// Sums channels into one mono stream. Returns only audio every channel has delivered, padding a stalled
/// channel with silence once the lead exceeds `maxLagSeconds`.
public struct Mixer: Sendable {
    private var buffers: [String: [UInt8]]
    private let maxLag: Int

    public init(_ names: [String], maxLagSeconds: Double = 0.5) {
        buffers = Dictionary(uniqueKeysWithValues: names.map { ($0, []) })
        maxLag = Int(maxLagSeconds * Double(LiveAudio.rate)) * 2
    }

    public mutating func add(_ name: String, _ pcm: Data) {
        buffers[name, default: []].append(contentsOf: pcm)
    }

    public mutating func drain(final: Bool = false) -> Data {
        let lengths = buffers.values.map(\.count)
        guard let longest = lengths.max(), let shortest = lengths.min() else { return Data() }
        var ready = (final || longest - shortest > maxLag) ? longest : shortest
        ready -= ready % 2
        guard ready > 0 else { return Data() }
        var mixed = [Int](repeating: 0, count: ready / 2)
        for name in Array(buffers.keys) {
            var buffer = buffers[name] ?? []
            let take = Array(buffer.prefix(ready))
            buffer.removeFirst(take.count)
            buffers[name] = buffer
            var index = 0
            while index + 1 < take.count {
                mixed[index / 2] += Int(Int16(bitPattern: UInt16(take[index]) | UInt16(take[index + 1]) << 8))
                index += 2
            }
        }
        var output = Data(capacity: ready)
        for total in mixed {
            let clipped = UInt16(bitPattern: Int16(max(-32768, min(32767, total))))
            output.append(UInt8(clipped & 0xff))
            output.append(UInt8(clipped >> 8))
        }
        return output
    }
}

// MARK: - Capture sources

public enum CaptureCommandError: Error, LocalizedError, Sendable {
    case unsupported(String)
    public var errorDescription: String? {
        switch self {
        case .unsupported(let platform): "live capture is not supported on \(platform)"
        }
    }
}

public enum LiveCapture {
    public static var currentPlatform: String {
        #if os(Linux)
        "linux"
        #elseif os(macOS)
        "darwin"
        #else
        "unknown"
        #endif
    }

    /// argv for a process writing 16 kHz mono s16le to stdout. `kind` is "mic" or "system".
    public static func sourceCommand(_ kind: String, platform: String? = nil, helper: String? = nil, env: [String: String]? = nil) throws -> [String] {
        let platform = platform ?? currentPlatform
        let env = env ?? ProcessInfo.processInfo.environment
        if platform.hasPrefix("linux") {
            let device = kind == "mic" ? "@DEFAULT_SOURCE@" : "@DEFAULT_MONITOR@"
            return ["parec", "--raw", "--format=s16le", "--rate=\(LiveAudio.rate)", "--channels=1", "--latency-msec=20", "--device=\(device)"]
        }
        if platform == "darwin" {
            if kind == "mic" {
                return ["ffmpeg", "-loglevel", "error", "-f", "avfoundation", "-i", ":default",
                        "-ar", String(LiveAudio.rate), "-ac", "1", "-f", "s16le", "-"]
            }
            return [helper ?? env["CALL_MEMORY_CAPTURE_HELPER"] ?? "call-memory-capture", "system"]
        }
        throw CaptureCommandError.unsupported(platform)
    }
}

/// A capture source: `nextChunk()` blocks until PCM is available and returns nil when capture has ended.
/// The macOS app can supply its own implementation (for example ScreenCaptureKit); Linux uses `ProcessPCMSource`.
public protocol PCMSource: AnyObject, Sendable {
    func start() throws
    func nextChunk() -> Data?
    func stop()
}

public typealias PCMSourceFactory = @Sendable (String) throws -> any PCMSource

public enum PCMSourceError: Error, LocalizedError, Sendable {
    case executableNotFound(String)
    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let name): "\(name) is not installed"
        }
    }
}

/// A capture subprocess (`parec` on Linux). Reads its stdout until the process ends or `stop()` is called.
public final class ProcessPCMSource: PCMSource, @unchecked Sendable {
    public let kind: String
    private let argv: [String]
    private let lock = NSLock()
    private var process: Process?
    private var descriptor: Int32 = -1

    public init(kind: String, argv: [String]? = nil) throws {
        self.kind = kind
        self.argv = try argv ?? LiveCapture.sourceCommand(kind)
    }

    public func start() throws {
        guard let program = argv.first, let executable = Self.find(program) else {
            throw PCMSourceError.executableNotFound(argv.first ?? "capture program")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(argv.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        lock.lock()
        self.process = process
        descriptor = pipe.fileHandleForReading.fileDescriptor
        lock.unlock()
        keepAlive = pipe
    }

    private var keepAlive: Pipe?

    public func nextChunk() -> Data? {
        let fd = lock.withLock { descriptor }
        guard fd >= 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: LiveAudio.frameBytes * 5)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 { return Data(buffer[0..<count]) }
            if count < 0 && errno == EINTR { continue }
            return nil
        }
    }

    public func stop() {
        let process = lock.withLock { self.process }
        guard let process, process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    static func find(_ program: String) -> String? {
        if program.contains("/") { return FileManager.default.isExecutableFile(atPath: program) ? program : nil }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/\(program)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
