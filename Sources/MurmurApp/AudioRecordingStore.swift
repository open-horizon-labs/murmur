import CoreMedia
import Foundation

enum AudioRecordingSource: String, Codable, CaseIterable, Hashable, Sendable {
    case system
    case microphone
}

struct AudioRecordingChunk: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let source: AudioRecordingSource
    let relativePath: String
    let offsetSeconds: Double
    let durationSeconds: Double
    let sampleCount: Int
}

struct AudioRecordingGap: Codable, Equatable, Sendable {
    let source: AudioRecordingSource?
    let offsetSeconds: Double
    let durationSeconds: Double
    let reason: String
}

struct AudioRecordingManifest: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var expectedSources: Set<AudioRecordingSource>
    let createdAt: Date
    var expiresAt: Date
    var finishedAt: Date?
    var isComplete: Bool
    var chunks: [AudioRecordingChunk]
    var gaps: [AudioRecordingGap]
    var analysisSavedAt: Date?
}

/// The capture callback only copies bounded data into this sink. All disk work
/// runs on the store's private serial queue.
protocol AudioRecordingSink: Sendable {
    func enqueue(sessionID: UUID, source: AudioRecordingSource, pcm16: Data, presentationTime: CMTime)
}

final class AudioRecordingStore: AudioRecordingSink, @unchecked Sendable {
    static let sampleRate = 24_000
    static let bytesPerSample = 2
    static let maximumChunkDurationSeconds = 300
    static let maximumPendingBytes = 8 * 1_024 * 1_024
    static let retention: TimeInterval = 24 * 60 * 60

    private struct Packet {
        let sessionID: UUID
        let source: AudioRecordingSource
        let pcm16: Data
        let presentationTime: CMTime
    }
    private struct OpenChunk {
        let id: UUID
        let source: AudioRecordingSource
        let relativePath: String
        var offsetSeconds: Double
        var sampleCount: Int
        let handle: FileHandle
    }

    private let rootURL: URL
    var checkpointRootURL: URL { rootURL }
    private let queue = DispatchQueue(label: "com.murmur.audio-recording-writer", qos: .utility)
    private let pendingLock = NSLock()
    private var pendingBytes = 0
    private var manifests: [UUID: AudioRecordingManifest] = [:]
    private var firstTimestamp: [UUID: Double] = [:]
    private var sequence: [UUID: Int] = [:]
    private var failedSessions: Set<UUID> = []
    private var lastEnd: [UUID: [AudioRecordingSource: Double]] = [:]
    private var gapWriteEnqueued: Set<UUID> = []
    private var openChunks: [UUID: [AudioRecordingSource: OpenChunk]] = [:]
    private var headerCheckpointSampleCount: [UUID: [AudioRecordingSource: Int]] = [:]
    private var activeSessions: Set<UUID> = []

    init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.rootURL = base.appendingPathComponent("me.openhorizons.murmur/Recordings", isDirectory: true)
        }
    }

    func begin(sessionID: UUID, expectedSources: Set<AudioRecordingSource> = []) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    let folder = self.folder(for: sessionID)
                    try FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
                    guard !FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) else {
                        throw AudioRecordingError.sessionAlreadyExists
                    }
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                    let now = Date()
                    let manifest = AudioRecordingManifest(
                        id: sessionID,
                        expectedSources: expectedSources,
                        createdAt: now,
                        expiresAt: now.addingTimeInterval(Self.retention),
                        finishedAt: nil,
                        isComplete: false,
                        chunks: [],
                        gaps: [],
                        analysisSavedAt: nil
                    )
                    self.manifests[sessionID] = manifest
                    self.firstTimestamp[sessionID] = nil
                    self.sequence[sessionID] = 0
                    self.lastEnd[sessionID] = [:]
                    self.openChunks[sessionID] = [:]
                    self.headerCheckpointSampleCount[sessionID] = [:]
                    self.activeSessions.insert(sessionID)
                    _ = self.pendingLock.withLock { self.gapWriteEnqueued.remove(sessionID) }
                    self.failedSessions.remove(sessionID)
                    try self.persist(manifest)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func enqueue(sessionID: UUID, source: AudioRecordingSource, pcm16: Data, presentationTime: CMTime) {
        guard !pcm16.isEmpty else { return }
        guard pcm16.count.isMultiple(of: Self.bytesPerSample) else {
            recordGap(sessionID: sessionID, source: source, timestamp: presentationTime, duration: 0, reason: "invalid PCM byte count")
            return
        }
        let bytes = pcm16.count
        let accepted = pendingLock.withLock { () -> Bool in
            guard pendingBytes + bytes <= Self.maximumPendingBytes else { return false }
            pendingBytes += bytes
            return true
        }
        guard accepted else {
            recordGap(sessionID: sessionID, source: source, timestamp: presentationTime,
                      duration: Double(bytes / Self.bytesPerSample) / Double(Self.sampleRate), reason: "writer buffer overflow (additional drops coalesced)")
            return
        }
        let packet = Packet(sessionID: sessionID, source: source, pcm16: pcm16, presentationTime: presentationTime)
        queue.async {
            defer { self.pendingLock.withLock { self.pendingBytes -= bytes } }
            self.write(packet)
        }
    }

    func finish(sessionID: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard var manifest = self.manifests[sessionID] else {
                    continuation.resume(throwing: AudioRecordingError.sessionNotFound)
                    return
                }
                manifest.finishedAt = Date()
                manifest.expiresAt = manifest.finishedAt!.addingTimeInterval(Self.retention)
                if self.failedSessions.contains(sessionID) || !manifest.gaps.isEmpty || !manifest.expectedSources.isSubset(of: Set(manifest.chunks.map(\.source))) { manifest.isComplete = false }
                else { manifest.isComplete = true }
                do {
                    self.closeAllChunks(sessionID: sessionID, manifest: &manifest)
                    if self.failedSessions.contains(sessionID) || !manifest.gaps.isEmpty || !manifest.expectedSources.isSubset(of: Set(manifest.chunks.map(\.source))) {
                        manifest.isComplete = false
                        for missing in manifest.expectedSources.subtracting(Set(manifest.chunks.map(\.source))) {
                            manifest.gaps.append(AudioRecordingGap(source: missing, offsetSeconds: 0, durationSeconds: 0, reason: "expected source produced no audio"))
                        }
                    }
                    try self.persist(manifest)
                    self.manifests[sessionID] = manifest
                    self.activeSessions.remove(sessionID)
                    if manifest.isComplete { continuation.resume() }
                    else { continuation.resume(throwing: AudioRecordingError.incompleteRecording) }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func recoverableSessions() async throws -> [AudioRecordingManifest] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[AudioRecordingManifest], Error>) in
            queue.async {
                do {
                    try FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
                    let folders = try FileManager.default.contentsOfDirectory(at: self.rootURL, includingPropertiesForKeys: [.isDirectoryKey])
                    var results: [AudioRecordingManifest] = []
                    for folder in folders {
                        let file = folder.appendingPathComponent("manifest.json")
                        guard let data = try? Data(contentsOf: file), var manifest = try? JSONDecoder().decode(AudioRecordingManifest.self, from: data) else { continue }
                        if self.activeSessions.contains(manifest.id) { continue }
                        guard manifest.expiresAt > Date() else { try FileManager.default.removeItem(at: folder); continue }
                        if manifest.analysisSavedAt != nil { try FileManager.default.removeItem(at: folder); continue }
                        let wasUnfinished = manifest.finishedAt == nil
                        if manifest.finishedAt == nil {
                            manifest.finishedAt = Date()
                            manifest.isComplete = false
                            manifest.gaps.append(AudioRecordingGap(source: nil, offsetSeconds: 0, durationSeconds: 0, reason: "capture interrupted before finish"))
                        }
                        var retainedChunks: [AudioRecordingChunk] = []
                        for chunk in manifest.chunks {
                            let url = self.folder(for: manifest.id).appendingPathComponent(chunk.relativePath)
                            if let bytes = try? self.recoverPayloadSize(at: url), bytes.isMultiple(of: Self.bytesPerSample) {
                                let samples = bytes / Self.bytesPerSample
                                if !wasUnfinished && samples != chunk.sampleCount {
                                    manifest.isComplete = false
                                    manifest.gaps.append(AudioRecordingGap(source: chunk.source,
                                        offsetSeconds: chunk.offsetSeconds + Double(min(samples, chunk.sampleCount)) / Double(Self.sampleRate),
                                        durationSeconds: Double(abs(samples - chunk.sampleCount)) / Double(Self.sampleRate),
                                        reason: "finished WAV size differs from saved manifest"))
                                }
                                if samples > 0 {
                                    retainedChunks.append(AudioRecordingChunk(id: chunk.id, source: chunk.source, relativePath: chunk.relativePath,
                                        offsetSeconds: chunk.offsetSeconds, durationSeconds: Double(samples) / Double(Self.sampleRate), sampleCount: samples))
                                } else {
                                    manifest.isComplete = false
                                    manifest.gaps.append(AudioRecordingGap(source: chunk.source, offsetSeconds: chunk.offsetSeconds,
                                        durationSeconds: chunk.durationSeconds, reason: "finished WAV is missing audio data"))
                                }
                            } else {
                                manifest.isComplete = false
                                manifest.gaps.append(AudioRecordingGap(source: chunk.source, offsetSeconds: chunk.offsetSeconds,
                                    durationSeconds: chunk.durationSeconds, reason: "recording WAV is missing or invalid"))
                            }
                        }
                        manifest.chunks = retainedChunks
                        if !manifest.gaps.isEmpty { manifest.isComplete = false }
                        try self.persist(manifest)
                        self.manifests[manifest.id] = manifest
                        results.append(manifest)
                    }
                    continuation.resume(returning: results.sorted { $0.createdAt < $1.createdAt })
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func manifest(sessionID: UUID) async throws -> AudioRecordingManifest {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AudioRecordingManifest, Error>) in
            queue.async {
                do {
                    let data = try Data(contentsOf: self.folder(for: sessionID).appendingPathComponent("manifest.json"))
                    continuation.resume(returning: try JSONDecoder().decode(AudioRecordingManifest.self, from: data))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func chunkURL(for chunk: AudioRecordingChunk, in manifest: AudioRecordingManifest) -> URL {
        // Paths are generated internally and constrained to the session folder.
        folder(for: manifest.id).appendingPathComponent(URL(fileURLWithPath: chunk.relativePath).lastPathComponent)
    }

    /// Call only after the final analysis has been durably saved by its owner.
    func markAnalysisSavedAndDelete(sessionID: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    let folder = self.folder(for: sessionID)
                    let data = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
                    var manifest = try JSONDecoder().decode(AudioRecordingManifest.self, from: data)
                    manifest.analysisSavedAt = Date()
                    try self.persist(manifest)
                    self.manifests[sessionID] = manifest
                    try FileManager.default.removeItem(at: folder)
                    self.manifests.removeValue(forKey: sessionID)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Remove this session's owned recording files after its parent session is deleted.
    func delete(sessionID: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    if var manifest = self.manifests[sessionID] {
                        self.closeAllChunks(sessionID: sessionID, manifest: &manifest)
                    }
                    let folder = self.folder(for: sessionID)
                    if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
                    self.manifests.removeValue(forKey: sessionID)
                    self.firstTimestamp.removeValue(forKey: sessionID)
                    self.lastEnd.removeValue(forKey: sessionID)
                    self.sequence.removeValue(forKey: sessionID)
                    self.openChunks.removeValue(forKey: sessionID)
                    self.activeSessions.remove(sessionID)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func cleanupExpired(now: Date = Date()) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
                    for folder in try FileManager.default.contentsOfDirectory(at: self.rootURL, includingPropertiesForKeys: nil) {
                        let url = folder.appendingPathComponent("manifest.json")
                        guard let data = try? Data(contentsOf: url), let manifest = try? JSONDecoder().decode(AudioRecordingManifest.self, from: data) else { continue }
                        if self.activeSessions.contains(manifest.id) { continue }
                        if manifest.analysisSavedAt != nil || manifest.expiresAt <= now { try FileManager.default.removeItem(at: folder); self.manifests.removeValue(forKey: manifest.id) }
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func write(_ packet: Packet) {
        guard var manifest = manifests[packet.sessionID], manifest.finishedAt == nil else { return }
        let duration = Double(packet.pcm16.count / Self.bytesPerSample) / Double(Self.sampleRate)
        guard packet.presentationTime.isNumeric else {
            addGap(&manifest, source: packet.source, offset: 0, duration: duration, reason: "invalid capture timestamp")
            saveAfterFailure(manifest, sessionID: packet.sessionID)
            return
        }
        let timestamp = CMTimeGetSeconds(packet.presentationTime)
        guard timestamp.isFinite else {
            addGap(&manifest, source: packet.source, offset: 0, duration: duration, reason: "invalid capture timestamp")
            saveAfterFailure(manifest, sessionID: packet.sessionID)
            return
        }
        var base = firstTimestamp[packet.sessionID] ?? timestamp
        if timestamp < base {
            let shift = base - timestamp
            base = timestamp
            firstTimestamp[packet.sessionID] = base
            manifest.chunks = manifest.chunks.map { chunk in
                AudioRecordingChunk(id: chunk.id, source: chunk.source, relativePath: chunk.relativePath,
                                    offsetSeconds: chunk.offsetSeconds + shift, durationSeconds: chunk.durationSeconds, sampleCount: chunk.sampleCount)
            }
            manifest.gaps = manifest.gaps.map { gap in
                AudioRecordingGap(source: gap.source, offsetSeconds: gap.offsetSeconds + shift, durationSeconds: gap.durationSeconds, reason: gap.reason)
            }
            for source in AudioRecordingSource.allCases {
                if var open = openChunks[packet.sessionID]?[source] { open.offsetSeconds += shift; openChunks[packet.sessionID]?[source] = open }
            }
            do { try persist(manifest); manifests[packet.sessionID] = manifest }
            catch { saveAfterFailure(manifest, sessionID: packet.sessionID) }
        } else {
            firstTimestamp[packet.sessionID] = base
        }
        let offset = max(0, timestamp - base)
        if let previousEnd = lastEnd[packet.sessionID]?[packet.source], timestamp > previousEnd + 0.002 {
            addGap(&manifest, source: packet.source, offset: previousEnd - base,
                   duration: timestamp - previousEnd, reason: "capture timestamp discontinuity")
            if let open = openChunks[packet.sessionID]?[packet.source] {
                closeChunk(open, sessionID: packet.sessionID, manifest: &manifest)
            }
            do { try persist(manifest); manifests[packet.sessionID] = manifest }
            catch { saveAfterFailure(manifest, sessionID: packet.sessionID) }
        } else if let previousEnd = lastEnd[packet.sessionID]?[packet.source], timestamp < previousEnd - 0.002 {
            addGap(&manifest, source: packet.source, offset: max(0, timestamp - base),
                   duration: previousEnd - timestamp + duration, reason: "capture timestamp overlap or reversal")
            if let open = openChunks[packet.sessionID]?[packet.source] {
                closeChunk(open, sessionID: packet.sessionID, manifest: &manifest)
            }
            saveAfterFailure(manifest, sessionID: packet.sessionID)
            return
        }
        lastEnd[packet.sessionID, default: [:]][packet.source] = max(timestamp, lastEnd[packet.sessionID]?[packet.source] ?? timestamp) + duration
        let maxSamples = Self.maximumChunkDurationSeconds * Self.sampleRate
        let sampleCount = packet.pcm16.count / Self.bytesPerSample
        var position = 0
        while position < sampleCount {
            if let current = openChunks[packet.sessionID]?[packet.source], current.sampleCount >= maxSamples {
                closeChunk(current, sessionID: packet.sessionID, manifest: &manifest)
            }
            var current = openChunks[packet.sessionID]?[packet.source]
            if current == nil {
                let chunkID = UUID()
                let index = sequence[packet.sessionID, default: 0]
                sequence[packet.sessionID] = index + 1
                let name = String(format: "%06d-%@-%@.wav", index, packet.source.rawValue, chunkID.uuidString)
                let file = folder(for: packet.sessionID).appendingPathComponent(name)
                do {
                    try writeWAVHeader(sampleCount: 0, to: file)
                    let handle = try FileHandle(forWritingTo: file)
                    try handle.seekToEnd()
                    current = OpenChunk(id: chunkID, source: packet.source, relativePath: name,
                                        offsetSeconds: offset + Double(position) / Double(Self.sampleRate), sampleCount: 0, handle: handle)
                    manifest.chunks.append(AudioRecordingChunk(id: chunkID, source: packet.source, relativePath: name,
                        offsetSeconds: current!.offsetSeconds, durationSeconds: 0, sampleCount: 0))
                    try persist(manifest)
                    manifests[packet.sessionID] = manifest
                    openChunks[packet.sessionID, default: [:]][packet.source] = current
                } catch {
                    addGap(&manifest, source: packet.source, offset: offset, duration: duration, reason: "disk write failed: \(error.localizedDescription)")
                    saveAfterFailure(manifest, sessionID: packet.sessionID)
                    return
                }
            }
            guard var segment = current else { return }
            let count = min(maxSamples - segment.sampleCount, sampleCount - position)
            let byteStart = position * Self.bytesPerSample
            let bytes = packet.pcm16.subdata(in: byteStart..<(byteStart + count * Self.bytesPerSample))
            let chunkOffset = offset + Double(position) / Double(Self.sampleRate)
            do {
                try segment.handle.write(contentsOf: bytes)
                segment.sampleCount += count
                // Patch/checkpoint headers about once per second. Data itself is
                // appended immediately; stop and chunk rollover always patch the
                // exact final size.
                let previousCheckpoint = headerCheckpointSampleCount[packet.sessionID]?[packet.source] ?? 0
                if segment.sampleCount - previousCheckpoint >= Self.sampleRate {
                    try segment.handle.synchronize()
                    try updateWAVHeader(sampleCount: segment.sampleCount, at: folder(for: packet.sessionID).appendingPathComponent(segment.relativePath))
                    headerCheckpointSampleCount[packet.sessionID, default: [:]][packet.source] = segment.sampleCount
                }
                openChunks[packet.sessionID, default: [:]][packet.source] = segment
            } catch {
                addGap(&manifest, source: packet.source, offset: chunkOffset, duration: Double(count) / Double(Self.sampleRate), reason: "disk write failed: \(error.localizedDescription)")
                saveAfterFailure(manifest, sessionID: packet.sessionID)
                return
            }
            position += count
        }
    }

    private func recordGap(sessionID: UUID, source: AudioRecordingSource, timestamp: CMTime, duration: Double, reason: String) {
        guard pendingLock.withLock({ gapWriteEnqueued.insert(sessionID).inserted }) else { return }
        queue.async {
            guard var manifest = self.manifests[sessionID] else { return }
            if self.failedSessions.contains(sessionID) { return }
            let time = timestamp.isNumeric ? CMTimeGetSeconds(timestamp) : 0
            let base = self.firstTimestamp[sessionID] ?? time
            if timestamp.isNumeric { self.firstTimestamp[sessionID] = base }
            self.addGap(&manifest, source: source, offset: max(0, time - base), duration: duration, reason: reason)
            self.saveAfterFailure(manifest, sessionID: sessionID)
        }
    }

    private func addGap(_ manifest: inout AudioRecordingManifest, source: AudioRecordingSource?, offset: Double, duration: Double, reason: String) {
        manifest.isComplete = false
        manifest.gaps.append(AudioRecordingGap(source: source, offsetSeconds: offset, durationSeconds: duration, reason: reason))
    }

    private func saveAfterFailure(_ manifest: AudioRecordingManifest, sessionID: UUID) {
        failedSessions.insert(sessionID)
        manifests[sessionID] = manifest
        do { try persist(manifest) } catch { /* The last persisted manifest remains an honest incomplete recovery record if available. */ }
    }

    private func persist(_ manifest: AudioRecordingManifest) throws {
        let folder = folder(for: manifest.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private func writeWAVHeader(sampleCount: Int, to url: URL) throws {
        try Data(repeating: 0, count: 44).write(to: url, options: .atomic)
        try updateWAVHeader(sampleCount: sampleCount, at: url)
    }

    private func updateWAVHeader(sampleCount: Int, at url: URL) throws {
        let byteCount = sampleCount * Self.bytesPerSample
        guard byteCount <= Int(UInt32.max) - 36 else { throw AudioRecordingError.chunkTooLarge }
        var header = Data()
        header.append(contentsOf: Array("RIFF".utf8)); header.appendLE(UInt32(byteCount + 36))
        header.append(contentsOf: Array("WAVEfmt ".utf8)); header.appendLE(UInt32(16)); header.appendLE(UInt16(1))
        header.appendLE(UInt16(1)); header.appendLE(UInt32(Self.sampleRate)); header.appendLE(UInt32(Self.sampleRate * Self.bytesPerSample))
        header.appendLE(UInt16(Self.bytesPerSample)); header.appendLE(UInt16(16))
        header.append(contentsOf: Array("data".utf8)); header.appendLE(UInt32(byteCount))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header)
        try handle.synchronize()
    }

    private func closeChunk(_ chunk: OpenChunk, sessionID: UUID, manifest: inout AudioRecordingManifest) {
        do {
            try chunk.handle.synchronize()
            try updateWAVHeader(sampleCount: chunk.sampleCount, at: folder(for: sessionID).appendingPathComponent(chunk.relativePath))
            try chunk.handle.close()
            headerCheckpointSampleCount[sessionID]?.removeValue(forKey: chunk.source)
        } catch {
            addGap(&manifest, source: chunk.source, offset: chunk.offsetSeconds,
                   duration: Double(chunk.sampleCount) / Double(Self.sampleRate), reason: "disk finalize failed: \(error.localizedDescription)")
            failedSessions.insert(sessionID)
            try? chunk.handle.close()
        }
        if let index = manifest.chunks.firstIndex(where: { $0.id == chunk.id }) {
            manifest.chunks[index] = AudioRecordingChunk(id: chunk.id, source: chunk.source, relativePath: chunk.relativePath,
                offsetSeconds: chunk.offsetSeconds, durationSeconds: Double(chunk.sampleCount) / Double(Self.sampleRate), sampleCount: chunk.sampleCount)
        }
        openChunks[sessionID]?.removeValue(forKey: chunk.source)
        manifests[sessionID] = manifest
        do { try persist(manifest) } catch { failedSessions.insert(sessionID); manifest.isComplete = false }
    }

    private func closeAllChunks(sessionID: UUID, manifest: inout AudioRecordingManifest) {
        let chunks = openChunks[sessionID].map { Array($0.values) } ?? []
        for chunk in chunks {
            closeChunk(chunk, sessionID: sessionID, manifest: &manifest)
        }
    }

    private func recoverPayloadSize(at url: URL) throws -> Int {
        let handle = try FileHandle(forReadingFrom: url)
        let data = try handle.read(upToCount: 44) ?? Data()
        try handle.close()
        guard data.count >= 44, String(data: data[0..<4], encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE",
              String(data: data[36..<40], encoding: .ascii) == "data" else { throw AudioRecordingError.invalidWAV }
        let fileSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        let payloadSize = max(0, (fileSize?.intValue ?? data.count) - 44)
        guard payloadSize.isMultiple(of: Self.bytesPerSample) else { throw AudioRecordingError.invalidWAV }
        try updateWAVHeader(sampleCount: payloadSize / Self.bytesPerSample, at: url)
        return payloadSize
    }

    private func folder(for id: UUID) -> URL { rootURL.appendingPathComponent(id.uuidString, isDirectory: true) }
}

enum AudioRecordingError: Error {
    case sessionAlreadyExists
    case sessionNotFound
    case chunkTooLarge
    case invalidWAV
    case incompleteRecording
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
