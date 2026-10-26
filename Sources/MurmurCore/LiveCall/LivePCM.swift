import Foundation

/// Blocking FIFO of PCM chunks with an end-of-stream marker. Producers (capture callbacks) never block.
public final class ChunkQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var chunks: [Data] = []
    private var closed = false

    public init() {}

    public func put(_ data: Data) {
        guard !data.isEmpty else { return }
        condition.lock()
        if !closed { chunks.append(data); condition.signal() }
        condition.unlock()
    }

    /// Mark the stream finished; `get()` returns nil once the remaining chunks are consumed.
    public func close() {
        condition.lock(); closed = true; condition.broadcast(); condition.unlock()
    }

    public func get() -> Data? {
        condition.lock(); defer { condition.unlock() }
        while chunks.isEmpty {
            if closed { return nil }
            condition.wait()
        }
        return chunks.removeFirst()
    }
}

/// A `PCMSource` fed by a platform capture callback. The macOS app pushes 16 kHz mono s16le chunks from
/// ScreenCaptureKit; the session reads them on its channel thread.
public final class QueuePCMSource: PCMSource, @unchecked Sendable {
    private let queue = ChunkQueue()
    private let onStart: @Sendable () throws -> Void
    private let onStop: @Sendable () -> Void

    public init(onStart: @escaping @Sendable () throws -> Void = {}, onStop: @escaping @Sendable () -> Void = {}) {
        self.onStart = onStart
        self.onStop = onStop
    }

    public func start() throws { try onStart() }
    public func nextChunk() -> Data? { queue.get() }
    public func stop() { queue.close(); onStop() }

    public func push(_ pcm: Data) { queue.put(pcm) }
    /// End of capture (also used when capture fails to start).
    public func finish() { queue.close() }
}

/// Streaming linear-interpolation resampler for mono s16le PCM (the Mac capture path delivers 24 kHz; the
/// recognizer wants 16 kHz). Keeps state across chunks so chunk boundaries are seamless.
public struct LinearResampler: Sendable {
    private let step: Double
    private var samples: [Int16] = []
    private var position = 0.0

    public init(from inputRate: Int, to outputRate: Int) {
        step = Double(inputRate) / Double(outputRate)
    }

    public mutating func process(_ data: Data) -> Data {
        let count = data.count / 2
        data.withUnsafeBytes { raw in
            for index in 0..<count {
                samples.append(Int16(bitPattern: raw.loadUnaligned(fromByteOffset: index * 2, as: UInt16.self).littleEndian))
            }
        }
        var output = Data()
        while Int(position) + 1 < samples.count {
            let index = Int(position)
            let fraction = position - Double(index)
            let value = Double(samples[index]) * (1 - fraction) + Double(samples[index + 1]) * fraction
            var sample = Int16(max(-32768, min(32767, value.rounded()))).littleEndian
            withUnsafeBytes(of: &sample) { output.append(contentsOf: $0) }
            position += step
        }
        let consumed = min(Int(position), samples.count)
        if consumed > 0 {
            samples.removeFirst(consumed)
            position -= Double(consumed)
        }
        return output
    }
}
