import Foundation

struct PCM16VoiceActivityDetector {
    enum Action: Equatable {
        case append(Data)
        case commit
    }

    struct Configuration: Equatable {
        var sampleRate = 24_000
        var speechRMS: Double = 420
        var preRollMilliseconds = 300
        var trailingSilenceMilliseconds = 600
        var maximumUtteranceMilliseconds = 15_000
    }

    private let configuration: Configuration
    private var preRoll = Data()
    private var utteranceBytes = 0
    private var trailingSilenceBytes = 0
    private var isSpeaking = false

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    mutating func reset() {
        preRoll = Data()
        utteranceBytes = 0
        trailingSilenceBytes = 0
        isSpeaking = false
    }

    mutating func consume(_ input: Data) -> [Action] {
        let evenByteCount = input.count - (input.count % MemoryLayout<Int16>.size)
        guard evenByteCount > 0 else { return [] }
        let audio = input.prefix(evenByteCount)
        let data = Data(audio)
        let isSpeech = rms(of: data) >= configuration.speechRMS

        guard isSpeaking else {
            if isSpeech {
                isSpeaking = true
                let prefix = preRoll
                preRoll = Data()
                utteranceBytes = prefix.count + data.count
                trailingSilenceBytes = 0
                return (prefix.isEmpty ? [] : [.append(prefix)]) + [.append(data)]
            }
            rememberPreRoll(data)
            return []
        }

        utteranceBytes += data.count
        if isSpeech {
            trailingSilenceBytes = 0
        } else {
            trailingSilenceBytes += data.count
        }

        var actions: [Action] = [.append(data)]
        if trailingSilenceBytes >= millisecondsToBytes(configuration.trailingSilenceMilliseconds)
            || utteranceBytes >= millisecondsToBytes(configuration.maximumUtteranceMilliseconds) {
            actions.append(.commit)
            utteranceBytes = 0
            trailingSilenceBytes = 0
            isSpeaking = false
            preRoll = Data()
        }
        return actions
    }

    private mutating func rememberPreRoll(_ data: Data) {
        let rawCapacity = max(0, millisecondsToBytes(configuration.preRollMilliseconds))
        let capacity = rawCapacity - rawCapacity % MemoryLayout<Int16>.size
        guard capacity > 0 else {
            preRoll = Data()
            return
        }

        // Build an owned, zero-based tail. Data.removeFirst can leave a nonzero
        // start index; later removeAll(keepingCapacity:) on that shared slice has
        // crashed in Foundation during real microphone sessions.
        if data.count >= capacity {
            var tail = Data()
            tail.reserveCapacity(capacity)
            tail.append(contentsOf: data.suffix(capacity))
            preRoll = tail
            return
        }

        let priorBytes = min(preRoll.count, capacity - data.count)
        var tail = Data()
        tail.reserveCapacity(priorBytes + data.count)
        tail.append(contentsOf: preRoll.suffix(priorBytes))
        tail.append(data)
        preRoll = tail
    }

    private func millisecondsToBytes(_ milliseconds: Int) -> Int {
        configuration.sampleRate * MemoryLayout<Int16>.size * milliseconds / 1_000
    }

    private func rms(of data: Data) -> Double {
        data.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return 0 }
            let sumSquares = samples.reduce(into: Double.zero) { total, sample in
                let value = Double(sample)
                total += value * value
            }
            return sqrt(sumSquares / Double(samples.count))
        }
    }
}
