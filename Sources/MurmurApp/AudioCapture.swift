@preconcurrency import AVFAudio
import CoreMedia
import Foundation
import ScreenCaptureKit

final class AudioCaptureCoordinator: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let sampleQueue = DispatchQueue(label: "com.murmur.audio-samples", qos: .userInteractive)
    private let encoder = PCM16Encoder()
    private let stateLock = NSLock()
    private var generation: UInt64 = 0
    private var stream: SCStream?
    private var captureStarted = false
    private var mode: AudioSourceMode = .system
    private var mixer = PCM16Mixer()
    private var audioHandler: (@Sendable (Data) -> Void)?
    private var recordingSessionID: UUID?
    private var recordingHandler: (@Sendable (UUID, AudioRecordingSource, Data, CMTime) -> Void)?
    private var errorHandler: (@Sendable (String) -> Void)?

    // Preserve the small capture protocol used by existing fakes and clients.
    func start(
        mode: AudioSourceMode,
        audioHandler: @escaping @Sendable (Data) -> Void,
        errorHandler: (@Sendable (String) -> Void)? = nil
    ) async throws {
        try await start(mode: mode, audioHandler: audioHandler, errorHandler: errorHandler,
                        recordingSessionID: nil, recordingHandler: nil)
    }

    func start(
        mode: AudioSourceMode,
        audioHandler: @escaping @Sendable (Data) -> Void,
        errorHandler: (@Sendable (String) -> Void)? = nil,
        recordingSessionID: UUID? = nil,
        recordingHandler: (@Sendable (UUID, AudioRecordingSource, Data, CMTime) -> Void)? = nil
    ) async throws {
        let runGeneration: UInt64? = stateLock.withLock {
            guard self.stream == nil else { return nil }
            generation &+= 1
            self.mode = mode
            mixer = PCM16Mixer()
            self.audioHandler = audioHandler
            self.errorHandler = errorHandler
            self.recordingSessionID = recordingSessionID
            self.recordingHandler = recordingHandler
            captureStarted = false
            return generation
        }
        guard let runGeneration else { return }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            guard isCurrent(runGeneration) else { return }
            clearState(for: runGeneration)
            throw error
        }
        guard isCurrent(runGeneration) else { return }
        let displays = content.displays
        guard let display = displays.first else {
            clearState(for: runGeneration)
            throw CaptureError.noDisplay
        }

        let ownApplication = content.applications.first {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let excludedApplications = ownApplication.map { [$0] } ?? []
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )

        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 1
        configuration.capturesAudio = mode.capturesSystemAudio
        configuration.captureMicrophone = mode.capturesMicrophone
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 24_000
        configuration.channelCount = 1

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            if mode.capturesSystemAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            }
            if mode.capturesMicrophone {
                try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)
            }
        } catch {
            guard isCurrent(runGeneration) else { return }
            clearState(for: runGeneration)
            throw error
        }

        let shouldStart = stateLock.withLock { () -> Bool in
            guard generation == runGeneration, self.stream == nil else { return false }
            self.stream = stream
            return true
        }
        guard shouldStart else { return }

        do {
            try await stream.startCapture()
        } catch {
            let wasCurrent = isCurrent(runGeneration)
            clearState(for: runGeneration)
            if wasCurrent { throw error }
            return
        }

        let stillCurrent = stateLock.withLock { () -> Bool in
            guard generation == runGeneration, self.stream === stream else { return false }
            captureStarted = true
            return true
        }
        if !stillCurrent {
            try? await stream.stopCapture()
        }
    }

    func stop() async {
        let stoppedRun: (SCStream?, PCM16Mixer) = stateLock.withLock {
            generation &+= 1
            let startedStream = captureStarted ? stream : nil
            audioHandler = nil
            errorHandler = nil
            recordingSessionID = nil
            recordingHandler = nil
            stream = nil
            captureStarted = false
            return (startedStream, mixer)
        }
        stoppedRun.1.reset()
        guard let streamToStop = stoppedRun.0 else { return }
        try? await streamToStop.stopCapture()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio || outputType == .microphone else { return }
        guard stateLock.withLock({ self.stream === stream && audioHandler != nil }) else { return }
        guard let data = encoder.encode(sampleBuffer: sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        stateLock.withLock {
            guard self.stream === stream, let handler = audioHandler else { return }
            if let recordingSessionID, let recordingHandler {
                let source: AudioRecordingSource = outputType == .microphone ? .microphone : .system
                // Recording receives the original encoded source before mixing.
                // The store only performs a bounded enqueue here; filesystem IO
                // happens on its dedicated writer queue.
                recordingHandler(recordingSessionID, source, data, timestamp)
            }
            if mode == .both {
                let source: PCM16Mixer.Source = outputType == .microphone ? .microphone : .system
                if let mixed = mixer.push(data, at: timestamp, from: source) {
                    handler(mixed)
                }
            } else {
                handler(data)
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let stoppedState: ((@Sendable (String) -> Void)?, PCM16Mixer?)? = stateLock.withLock {
            guard self.stream === stream else { return nil }
            generation &+= 1
            self.stream = nil
            captureStarted = false
            audioHandler = nil
            recordingSessionID = nil
            recordingHandler = nil
            let callback = errorHandler
            errorHandler = nil
            return (callback, mixer)
        }
        guard let stoppedState else { return }
        stoppedState.1?.reset()
        stoppedState.0?(error.localizedDescription)
    }

    private func isCurrent(_ runGeneration: UInt64) -> Bool {
        stateLock.withLock { generation == runGeneration }
    }

    private func clearState(for runGeneration: UInt64) {
        stateLock.withLock {
            guard generation == runGeneration else { return }
            stream = nil
            captureStarted = false
            audioHandler = nil
            errorHandler = nil
            recordingSessionID = nil
            recordingHandler = nil
        }
    }
}

private final class PCM16Encoder: @unchecked Sendable {
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24_000,
        channels: 1,
        interleaved: true
    )!

    func encode(sampleBuffer: CMSampleBuffer) -> Data? {
        guard
            sampleBuffer.isValid,
            CMSampleBufferDataIsReady(sampleBuffer),
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
        else { return nil }
        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)

        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0 else { return nil }
        let sourceFrames = AVAudioFrameCount(sampleCount)
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: sourceFrames
        ) else { return nil }
        sourceBuffer.frameLength = sourceFrames

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(sampleCount),
            into: sourceBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else { return nil }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let targetCapacity = AVAudioFrameCount(ceil(Double(sourceFrames) * ratio)) + 32
        guard
            let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity),
            let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        else { return nil }

        let input = ConverterInput(buffer: sourceBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: targetBuffer, error: &conversionError) { _, inputStatus in
            if input.wasSupplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            input.wasSupplied = true
            inputStatus.pointee = .haveData
            return input.buffer
        }

        guard
            conversionError == nil,
            status != .error,
            targetBuffer.frameLength > 0,
            let channel = targetBuffer.int16ChannelData?[0]
        else { return nil }

        let byteCount = Int(targetBuffer.frameLength) * MemoryLayout<Int16>.size
        return Data(bytes: channel, count: byteCount)
    }
}

private final class ConverterInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var wasSupplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

struct TimestampedPCM16: Equatable, Sendable {
    let startSample: Int64
    let samples: [Int16]
}

final class PCM16Mixer: @unchecked Sendable {
    enum Source {
        case system
        case microphone
    }

    static let sampleRate: Int64 = 24_000
    private struct SamplePair {
        var system: Int16?
        var microphone: Int16?
    }

    private let lock = NSLock()
    private var pending: [Int64: SamplePair] = [:]
    private var nextSample: Int64?
    private var latestEnd: Int64?
    private var holdbackSamples: Int64 = 2_400

    func push(_ data: Data, at timestamp: CMTime, from source: Source) -> Data? {
        guard timestamp.isNumeric else { return nil }
        let pcm = TimestampedPCM16(
            startSample: Int64((CMTimeGetSeconds(timestamp) * Double(Self.sampleRate)).rounded()),
            samples: Self.samples(from: data)
        )
        guard !pcm.samples.isEmpty else { return nil }
        return lock.withLock { () -> Data? in
            let chunkEnd = pcm.startSample + Int64(pcm.samples.count)
            holdbackSamples = max(holdbackSamples, min(Int64(pcm.samples.count), Self.sampleRate))
            if let latestEnd, pcm.startSample - latestEnd > Self.sampleRate {
                // A discontinuity over one second starts a fresh timeline rather
                // than allocating a huge silence buffer.
                pending.removeAll(keepingCapacity: true)
                nextSample = pcm.startSample
                self.latestEnd = nil
            }
            if nextSample == nil { nextSample = pcm.startSample }
            for (offset, sample) in pcm.samples.enumerated() {
                let sampleIndex = pcm.startSample + Int64(offset)
                guard sampleIndex >= (nextSample ?? sampleIndex) else { continue }
                var pair = pending[sampleIndex] ?? SamplePair()
                switch source {
                case .system: pair.system = sample
                case .microphone: pair.microphone = sample
                }
                pending[sampleIndex] = pair
            }

            latestEnd = max(latestEnd ?? chunkEnd, chunkEnd)
            // A short jitter window lets the other ScreenCaptureKit output arrive
            // before samples are committed. Missing samples then contribute zero.
            let emitThrough = (latestEnd ?? chunkEnd) - holdbackSamples
            guard let start = nextSample, emitThrough > start else { return nil }
            let sampleCount = Int(emitThrough - start)
            var output = Array(repeating: Int16.zero, count: sampleCount)
            for index in 0..<sampleCount {
                if let pair = pending.removeValue(forKey: start + Int64(index)) {
                    output[index] = Int16(clamping: Int32(pair.system ?? 0) + Int32(pair.microphone ?? 0))
                }
            }
            nextSample = emitThrough
            return Self.data(from: output)
        }
    }

    func reset() {
        lock.withLock {
            pending.removeAll(keepingCapacity: true)
            nextSample = nil
            latestEnd = nil
            holdbackSamples = 2_400
        }
    }

    private static func samples(from data: Data) -> [Int16] {
        data.withUnsafeBytes { $0.bindMemory(to: Int16.self).map { $0 } }
    }

    private static func data(from samples: [Int16]) -> Data {
        samples.withUnsafeBytes { Data($0) }
    }
}

enum CaptureError: LocalizedError {
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .noDisplay: "No display is available for system-audio capture."
        }
    }
}
