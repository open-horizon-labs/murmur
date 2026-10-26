import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct PostCallTranscriptSegment: Codable, Sendable, Equatable {
    let startSeconds: Double
    let endSeconds: Double
    let text: String
}

struct PostCallBatchTranscript: Codable, Sendable, Equatable {
    let text: String
    let segments: [PostCallTranscriptSegment]

    init(text: String, segments: [PostCallTranscriptSegment] = []) {
        self.text = text
        self.segments = segments
    }
}

protocol BatchAudioTranscribing: Sendable {
    func transcribe(fileURL: URL, fileName: String, model: String) async throws -> PostCallBatchTranscript
}

enum OpenAIBatchTranscriptionError: LocalizedError, Equatable {
    case invalidModel
    case invalidAudioFile
    case fileTooLarge(Int)
    case invalidResponse
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidModel: "Choose a batch transcription model."
        case .invalidAudioFile: "The recording chunk could not be read as a WAV file."
        case .fileTooLarge(let bytes): "The recording chunk is \(bytes) bytes; transcription uploads are limited to 25 MB."
        case .invalidResponse: "The transcription service returned an unreadable response."
        case .httpStatus(let code, let body): "Transcription failed (HTTP \(code)): \(body)"
        }
    }
}

/// OpenAI's file transcription endpoint accepts WAV via multipart/form-data.
/// The model is passed through unchanged so account-specific/future model IDs work.
struct OpenAIBatchAudioTranscriber: BatchAudioTranscribing {
    private let apiKey: @Sendable () async throws -> String
    private let session: URLSession
    private let endpoint: URL
    private let maximumFileBytes = 25 * 1024 * 1024

    init(
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
        apiKey: @escaping @Sendable () async throws -> String
    ) {
        self.session = session
        self.endpoint = endpoint
        self.apiKey = apiKey
    }

    func transcribe(fileURL: URL, fileName: String, model: String) async throws -> PostCallBatchTranscript {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw OpenAIBatchTranscriptionError.invalidModel }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard byteCount > 0 else { throw OpenAIBatchTranscriptionError.invalidAudioFile }
        guard byteCount <= maximumFileBytes else { throw OpenAIBatchTranscriptionError.fileTooLarge(byteCount) }
        let audio = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        guard audio.count >= 44, String(data: audio.prefix(4), encoding: .ascii) == "RIFF",
              String(data: audio.dropFirst(8).prefix(4), encoding: .ascii) == "WAVE" else {
            throw OpenAIBatchTranscriptionError.invalidAudioFile
        }
        let credential = try await apiKey()
        try Task.checkCancellation()

        let boundary = "Murmur-\(UUID().uuidString)"
        var body = Data()
        appendField("model", value: model, boundary: boundary, to: &body)
        appendField("response_format", value: "json", boundary: boundary, to: &body)
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeFilename(fileName))\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw OpenAIBatchTranscriptionError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(decoding: data.prefix(2_000), as: UTF8.self)
            throw OpenAIBatchTranscriptionError.httpStatus(http.statusCode, detail)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else { throw OpenAIBatchTranscriptionError.invalidResponse }
        let segments = (object["segments"] as? [[String: Any]] ?? []).compactMap { item -> PostCallTranscriptSegment? in
            guard let start = item["start"] as? Double, let end = item["end"] as? Double,
                  let value = item["text"] as? String,
                  start.isFinite, end.isFinite, start >= 0, end >= start else { return nil }
            return PostCallTranscriptSegment(startSeconds: start, endSeconds: end, text: value)
        }
        return PostCallBatchTranscript(text: text, segments: segments)
    }

    private func appendField(_ name: String, value: String, boundary: String, to data: inout Data) {
        data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    private func safeFilename(_ name: String) -> String {
        let candidate = URL(fileURLWithPath: name).lastPathComponent
        return candidate.lowercased().hasSuffix(".wav") ? candidate : "recording.wav"
    }
}

struct PostCallTranscriptionCheckpoint: Codable, Sendable, Equatable {
    struct CompletedWindow: Codable, Sendable, Equatable {
        let windowID: String
        let chunkIDs: [UUID]
        let firstAudibleOffsetSeconds: Double
        let transcript: PostCallBatchTranscript
    }

    let sessionID: UUID
    var revisionID: UUID
    var model: String
    var completedWindows: [CompletedWindow]
    var inFlightWindowIDs: [String]
    var updatedAt: Date
}

protocol PostCallTranscriptionCheckpointStoring: Sendable {
    func load(sessionID: UUID) async throws -> PostCallTranscriptionCheckpoint?
    func save(_ checkpoint: PostCallTranscriptionCheckpoint) async throws
}

actor JSONPostCallTranscriptionCheckpointStore: PostCallTranscriptionCheckpointStoring {
    private let directory: URL

    init(directory: URL) { self.directory = directory }

    func load(sessionID: UUID) throws -> PostCallTranscriptionCheckpoint? {
        let url = checkpointURL(sessionID)
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(PostCallTranscriptionCheckpoint.self, from: Data(contentsOf: url))
    }

    func save(_ checkpoint: PostCallTranscriptionCheckpoint) throws {
        let folder = checkpointURL(checkpoint.sessionID).deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: folder.path),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try JSONEncoder().encode(checkpoint)
        try data.write(to: checkpointURL(checkpoint.sessionID), options: .atomic)
    }

    private func checkpointURL(_ sessionID: UUID) -> URL {
        directory.appendingPathComponent(sessionID.uuidString, isDirectory: true).appendingPathComponent("transcription-checkpoint.json")
    }
}

struct PostCallTranscriptionResult: Sendable, Equatable {
    let revisionID: UUID
    let model: String
    let entries: [TranscriptEntry]
    let completedChunkIDs: [UUID]
    let coverageGaps: [AudioRecordingGap]
    let captureComplete: Bool
}

enum PostCallTranscriptionError: LocalizedError {
    case incompleteRecording
    case expiredRecording
    case noAudio
    case invalidManifest
    case uncertainPriorRequest(String)
    case missingChunk(UUID)

    var errorDescription: String? {
        switch self {
        case .incompleteRecording: "The recording has not been finalized yet."
        case .expiredRecording: "The recording retention period has ended; expired audio was not uploaded."
        case .noAudio: "The recording contains no usable audio chunks."
        case .invalidManifest: "The recording manifest has invalid chunk timing or contains too many chunks."
        case .uncertainPriorRequest(let id): "The previous transcription request for window \(id) may have completed. It was not repeated to avoid a duplicate charge."
        case .missingChunk(let id): "The recording chunk \(id) is unavailable."
        }
    }
}

struct PostCallTranscriptionCoordinator: Sendable {
    private let transcriber: any BatchAudioTranscribing
    private let checkpointStore: any PostCallTranscriptionCheckpointStoring

    init(transcriber: any BatchAudioTranscribing, checkpointStore: any PostCallTranscriptionCheckpointStoring) {
        self.transcriber = transcriber
        self.checkpointStore = checkpointStore
    }

    func transcribe(
        manifest: AudioRecordingManifest,
        sessionID: UUID,
        transcriptSessionID: UUID? = nil,
        chunkURL: @Sendable (AudioRecordingChunk) async throws -> URL,
        model: String,
        allowRetryUncertain: Bool = false,
        allowIncomplete: Bool = false
    ) async throws -> PostCallTranscriptionResult {
        guard manifest.expiresAt > Date() else { throw PostCallTranscriptionError.expiredRecording }
        guard manifest.isComplete || allowIncomplete else { throw PostCallTranscriptionError.incompleteRecording }
        guard !manifest.chunks.isEmpty else { throw PostCallTranscriptionError.noAudio }
        guard manifest.chunks.count <= 1_000 else {
            throw PostCallTranscriptionError.invalidManifest
        }
        guard manifest.chunks.allSatisfy({
            $0.offsetSeconds.isFinite && $0.offsetSeconds >= 0 &&
            $0.durationSeconds.isFinite && $0.durationSeconds > 0 && $0.durationSeconds <= 300 &&
            $0.sampleCount > 0
        }) else { throw PostCallTranscriptionError.invalidManifest }
        for source in Set(manifest.chunks.map(\.source)) {
            let chunks = manifest.chunks.filter { $0.source == source }.sorted { $0.offsetSeconds < $1.offsetSeconds }
            for pair in zip(chunks, chunks.dropFirst()) where pair.0.offsetSeconds + pair.0.durationSeconds > pair.1.offsetSeconds + 0.001 {
                throw PostCallTranscriptionError.invalidManifest
            }
        }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw OpenAIBatchTranscriptionError.invalidModel }
        var checkpoint = try await checkpointStore.load(sessionID: sessionID)
        if checkpoint?.model != model {
            checkpoint = PostCallTranscriptionCheckpoint(
                sessionID: sessionID, revisionID: UUID(), model: model,
                completedWindows: [], inFlightWindowIDs: [], updatedAt: Date()
            )
        }
        guard var current = checkpoint else { throw PostCallTranscriptionError.invalidManifest }
        if !current.inFlightWindowIDs.isEmpty {
            guard allowRetryUncertain else { throw PostCallTranscriptionError.uncertainPriorRequest(current.inFlightWindowIDs[0]) }
            current.inFlightWindowIDs.removeAll()
            current.updatedAt = Date()
            try await checkpointStore.save(current)
        }
        var checkpointValue = current
        let completedWindows = Set(checkpointValue.completedWindows.map(\.windowID))
        let orderedChunks = manifest.chunks.sorted { $0.offsetSeconds < $1.offsetSeconds }
        let windowSeconds = 300.0
        let windowCount = Int(ceil((orderedChunks.map { $0.offsetSeconds + $0.durationSeconds }.max() ?? 0) / windowSeconds))
        guard windowCount <= 1_000 else { throw PostCallTranscriptionError.invalidManifest }

        for windowIndex in 0..<windowCount {
            try Task.checkCancellation()
            guard manifest.expiresAt > Date() else { throw PostCallTranscriptionError.expiredRecording }
            let windowID = "window-\(windowIndex)"
            guard !completedWindows.contains(windowID) else { continue }
            try Task.checkCancellation()
            let windowStart = Double(windowIndex) * windowSeconds
            let windowEnd = windowStart + windowSeconds
            let chunks = orderedChunks.filter { $0.offsetSeconds < windowEnd && $0.offsetSeconds + $0.durationSeconds > windowStart }
            guard !chunks.isEmpty else { continue }
            let actualEnd = min(windowEnd, chunks.map { $0.offsetSeconds + $0.durationSeconds }.max() ?? windowEnd)
            let pcm = try await Self.mixedWindowPCM(chunks: chunks, windowStart: windowStart, windowDuration: actualEnd - windowStart, chunkURL: chunkURL)
            try Task.checkCancellation()
            guard let firstAudible = pcm.firstIndex(where: { $0 != 0 }),
                  let lastAudible = pcm.lastIndex(where: { $0 != 0 }) else { continue }
            let audibleSamples = Array(pcm[firstAudible...lastAudible])
            let wav = Self.wavData(from: audibleSamples)
            guard wav.count <= 25 * 1024 * 1024 else { throw OpenAIBatchTranscriptionError.fileTooLarge(wav.count) }
            guard let anchor = chunks.first else { continue }
            let anchorURL = try await chunkURL(anchor)
            let ownedDirectory = anchorURL.deletingLastPathComponent()
            try Task.checkCancellation()
            guard manifest.expiresAt > Date(), FileManager.default.fileExists(atPath: ownedDirectory.path) else {
                throw PostCallTranscriptionError.expiredRecording
            }
            let fileURL = ownedDirectory.appendingPathComponent(".postcall-\(sessionID.uuidString)-\(windowIndex).wav")
            try wav.write(to: fileURL, options: .atomic)
            defer { try? FileManager.default.removeItem(at: fileURL) }

            checkpointValue.inFlightWindowIDs = [windowID]
            checkpointValue.updatedAt = Date()
            try await checkpointStore.save(checkpointValue)
            do {
                let transcript = try await transcriber.transcribe(fileURL: fileURL, fileName: fileURL.lastPathComponent, model: model)
                try Task.checkCancellation()
                guard manifest.expiresAt > Date(), FileManager.default.fileExists(atPath: ownedDirectory.path) else {
                    throw PostCallTranscriptionError.expiredRecording
                }
                checkpointValue.completedWindows.append(.init(
                    windowID: windowID, chunkIDs: chunks.map(\.id),
                    firstAudibleOffsetSeconds: windowStart + Double(firstAudible) / 24_000,
                    transcript: transcript
                ))
                checkpointValue.inFlightWindowIDs.removeAll { $0 == windowID }
                checkpointValue.updatedAt = Date()
                try await checkpointStore.save(checkpointValue)
            } catch let error as OpenAIBatchTranscriptionError {
                if case .httpStatus(let code, _) = error, (400..<500).contains(code) {
                    checkpointValue.inFlightWindowIDs.removeAll { $0 == windowID }
                    checkpointValue.updatedAt = Date()
                    try await checkpointStore.save(checkpointValue)
                }
                throw error
            }
        }

        let transcriptEntries: [TranscriptEntry] = checkpointValue.completedWindows.flatMap { saved -> [TranscriptEntry] in
            let entrySessionID = transcriptSessionID ?? sessionID
            guard Int(saved.windowID.replacingOccurrences(of: "window-", with: "")) != nil else { return [] }
            let text = saved.transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            return Self.splitVerbatim(text, maximumUTF8Bytes: 3_000).enumerated().map { partIndex, part in
                TranscriptEntry(
                    id: "postcall:\(entrySessionID.uuidString.lowercased()):\(sessionID.uuidString.lowercased()):\(checkpointValue.revisionID.uuidString.lowercased()):\(saved.windowID):\(partIndex)",
                    timestamp: manifest.createdAt.addingTimeInterval(saved.firstAudibleOffsetSeconds),
                    text: part, isFinal: true, wasInterrupted: nil
                )
            }
        }.sorted { $0.timestamp < $1.timestamp }
        return PostCallTranscriptionResult(
            revisionID: checkpointValue.revisionID,
            model: model,
            entries: transcriptEntries,
            completedChunkIDs: Array(Set(checkpointValue.completedWindows.flatMap(\.chunkIDs))).sorted { $0.uuidString < $1.uuidString },
            coverageGaps: manifest.gaps,
            captureComplete: manifest.isComplete
        )
    }

    private static func mixedWindowPCM(
        chunks: [AudioRecordingChunk], windowStart: Double, windowDuration: Double,
        chunkURL: @Sendable (AudioRecordingChunk) async throws -> URL
    ) async throws -> [Int16] {
        let frames = Int(ceil(windowDuration * 24_000))
        var sums = [Int32](repeating: 0, count: frames)
        var contributors = [UInt8](repeating: 0, count: frames)
        for chunk in chunks {
            let url = try await chunkURL(chunk)
            guard FileManager.default.fileExists(atPath: url.path) else { throw PostCallTranscriptionError.missingChunk(chunk.id) }
            let source = try readPCM16Mono24kWAV(url: url)
            guard source.count == chunk.sampleCount else { throw PostCallTranscriptionError.invalidManifest }
            let sourceOffset = Int((chunk.offsetSeconds - windowStart) * 24_000)
            guard sourceOffset >= -source.count, sourceOffset < frames else { continue }
            let destinationStart = max(0, sourceOffset)
            let sourceStart = max(0, -sourceOffset)
            let count = min(source.count - sourceStart, frames - destinationStart)
            guard count > 0 else { continue }
            for index in 0..<count {
                let destination = destinationStart + index
                let sample = source[sourceStart + index]
                // Digital zero does not count as an active contributor, so a
                // silent parallel track cannot attenuate a quiet source sample.
                guard sample != 0 else { continue }
                sums[destination] += Int32(sample)
                contributors[destination] &+= 1
            }
        }
        return sums.indices.map { index in
            guard contributors[index] > 0 else { return 0 }
            let sample = sums[index] / Int32(contributors[index])
            return Int16(clamping: sample)
        }
    }

    private static func readPCM16Mono24kWAV(url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count >= 44, data.ascii(at: 0, count: 4) == "RIFF", data.ascii(at: 8, count: 4) == "WAVE" else {
            throw OpenAIBatchTranscriptionError.invalidAudioFile
        }
        var offset = 12
        var pcmFormat: UInt16?
        var channels: UInt16?
        var sampleRate: UInt32?
        var bitsPerSample: UInt16?
        var audioRange: Range<Int>?
        while offset + 8 <= data.count {
            let kind = data.ascii(at: offset, count: 4)
            let length = Int(data.readUInt32LE(at: offset + 4))
            let start = offset + 8
            guard length >= 0, start + length <= data.count else { break }
            if kind == "fmt ", length >= 16 {
                pcmFormat = data.readUInt16LE(at: start)
                channels = data.readUInt16LE(at: start + 2)
                sampleRate = data.readUInt32LE(at: start + 4)
                bitsPerSample = data.readUInt16LE(at: start + 14)
            } else if kind == "data" {
                audioRange = start..<(start + length)
            }
            offset = start + length + (length & 1)
        }
        guard pcmFormat == 1, channels == 1, sampleRate == 24_000, bitsPerSample == 16, let audioRange else {
            throw OpenAIBatchTranscriptionError.invalidAudioFile
        }
        return stride(from: audioRange.lowerBound, to: audioRange.upperBound - 1, by: 2).map {
            Int16(bitPattern: data.readUInt16LE(at: $0))
        }
    }

    private static func wavData(from samples: [Int16]) -> Data {
        var data = Data()
        data.appendASCII("RIFF"); data.appendUInt32LE(UInt32(samples.count * 2 + 36)); data.appendASCII("WAVE")
        data.appendASCII("fmt "); data.appendUInt32LE(16); data.appendUInt16LE(1); data.appendUInt16LE(1)
        data.appendUInt32LE(24_000); data.appendUInt32LE(48_000); data.appendUInt16LE(2); data.appendUInt16LE(16)
        data.appendASCII("data"); data.appendUInt32LE(UInt32(samples.count * 2))
        for sample in samples { data.appendUInt16LE(UInt16(bitPattern: sample)) }
        return data
    }

    private static func splitVerbatim(_ text: String, maximumUTF8Bytes: Int) -> [String] {
        var parts: [String] = []
        var current = String.UnicodeScalarView()
        var byteCount = 0
        for scalar in text.unicodeScalars {
            let width = scalar.utf8.count
            if byteCount + width > maximumUTF8Bytes, !current.isEmpty {
                parts.append(String(current))
                current = String.UnicodeScalarView()
                byteCount = 0
            }
            current.append(scalar)
            byteCount += width
        }
        if !current.isEmpty { parts.append(String(current)) }
        return parts
    }
}

private extension Data {
    func ascii(at offset: Int, count: Int) -> String { String(decoding: self[offset..<(offset + count)], as: UTF8.self) }
    func readUInt16LE(at offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }
    func readUInt32LE(at offset: Int) -> UInt32 { UInt32(readUInt16LE(at: offset)) | UInt32(readUInt16LE(at: offset + 2)) << 16 }
    mutating func appendASCII(_ value: String) { append(contentsOf: value.utf8) }
    mutating func appendUInt16LE(_ value: UInt16) { append(UInt8(value & 0xff)); append(UInt8(value >> 8)) }
    mutating func appendUInt32LE(_ value: UInt32) { appendUInt16LE(UInt16(value & 0xffff)); appendUInt16LE(UInt16(value >> 16)) }
}
