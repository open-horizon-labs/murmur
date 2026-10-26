#if canImport(CoreMedia)
import CoreMedia
#endif
import Foundation
import XCTest
@testable import MurmurCore

final class AudioRecordingStoreTests: XCTestCase {
    func testKeepsSystemAndMicrophoneInSeparateValidWAVFiles() async throws {
        let (root, store, id) = try makeStore()
        try await store.begin(sessionID: id, expectedSources: [.system, .microphone])
        store.enqueue(sessionID: id, source: .system, pcm16: pcm(samples: 240), presentationTime: time(0))
        store.enqueue(sessionID: id, source: .microphone, pcm16: pcm(samples: 480), presentationTime: time(120))
        try await store.finish(sessionID: id)

        let manifest = try await store.manifest(sessionID: id)
        XCTAssertTrue(manifest.isComplete)
        XCTAssertEqual(Set(manifest.chunks.map(\.source)), [.system, .microphone])
        XCTAssertEqual(manifest.chunks.map(\.sampleCount).sorted(), [240, 480])
        for chunk in manifest.chunks {
            let data = try Data(contentsOf: store.chunkURL(for: chunk, in: manifest))
            XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
            XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
            XCTAssertEqual(String(data: data[36..<40], encoding: .ascii), "data")
            XCTAssertEqual(readUInt32(data, 40), UInt32(chunk.sampleCount * 2))
            XCTAssertEqual(data.count, 44 + chunk.sampleCount * 2)
        }
        try? FileManager.default.removeItem(at: root)
    }

    func testTimestampDiscontinuityIsExplicitAndSplitsSourceTimeline() async throws {
        let (root, store, id) = try makeStore()
        try await store.begin(sessionID: id)
        store.enqueue(sessionID: id, source: .microphone, pcm16: pcm(samples: 240), presentationTime: time(0))
        store.enqueue(sessionID: id, source: .microphone, pcm16: pcm(samples: 240), presentationTime: time(2_640))
        do { try await store.finish(sessionID: id); XCTFail("expected incomplete recording") }
        catch AudioRecordingError.incompleteRecording { }

        let manifest = try await store.manifest(sessionID: id)
        XCTAssertFalse(manifest.isComplete)
        XCTAssertEqual(manifest.chunks.count, 2)
        XCTAssertEqual(manifest.gaps.count, 1)
        XCTAssertEqual(manifest.gaps[0].reason, "capture timestamp discontinuity")
        XCTAssertEqual(manifest.gaps[0].durationSeconds, 0.1, accuracy: 0.0001)
        try? FileManager.default.removeItem(at: root)
    }

    func testOddByteInputBecomesAnIncompleteGapWithoutCorruptWAV() async throws {
        let (root, store, id) = try makeStore()
        try await store.begin(sessionID: id)
        store.enqueue(sessionID: id, source: .system, pcm16: Data([1, 2, 3]), presentationTime: time(0))
        do { try await store.finish(sessionID: id); XCTFail("expected incomplete recording") }
        catch AudioRecordingError.incompleteRecording { }
        let manifest = try await store.manifest(sessionID: id)
        XCTAssertFalse(manifest.isComplete)
        XCTAssertTrue(manifest.chunks.isEmpty)
        XCTAssertEqual(manifest.gaps.first?.reason, "invalid PCM byte count")
        try? FileManager.default.removeItem(at: root)
    }

    func testReversedTimestampDropsOverlappingPacketAndMarksIncomplete() async throws {
        let (root, store, id) = try makeStore()
        try await store.begin(sessionID: id)
        store.enqueue(sessionID: id, source: .system, pcm16: pcm(samples: 960), presentationTime: time(0))
        store.enqueue(sessionID: id, source: .system, pcm16: pcm(samples: 960), presentationTime: time(240))
        do { try await store.finish(sessionID: id); XCTFail("expected incomplete recording") }
        catch AudioRecordingError.incompleteRecording { }
        let manifest = try await store.manifest(sessionID: id)
        XCTAssertFalse(manifest.isComplete)
        XCTAssertEqual(manifest.chunks.map(\.sampleCount), [960])
        XCTAssertEqual(manifest.gaps.first?.reason, "capture timestamp overlap or reversal")
        try? FileManager.default.removeItem(at: root)
    }

    func testWriterOverflowIsBoundedAndRecordedAsIncomplete() async throws {
        let (root, store, id) = try makeStore()
        try await store.begin(sessionID: id)
        let oversized = Data(repeating: 0, count: AudioRecordingStore.maximumPendingBytes + 2)
        store.enqueue(sessionID: id, source: .microphone, pcm16: oversized, presentationTime: time(0))
        do { try await store.finish(sessionID: id); XCTFail("expected incomplete recording") }
        catch AudioRecordingError.incompleteRecording { }
        let manifest = try await store.manifest(sessionID: id)
        XCTAssertFalse(manifest.isComplete)
        XCTAssertEqual(manifest.gaps.first?.reason, "writer buffer overflow (additional drops coalesced)")
        try? FileManager.default.removeItem(at: root)
    }

    func testChunkBoundaryProducesAtMostFiveMinuteWAVsWithCorrectHeaders() async throws {
        let (root, store, id) = try makeStore()
        try await store.begin(sessionID: id)
        let firstSamples = 150 * AudioRecordingStore.sampleRate
        let secondSamples = 151 * AudioRecordingStore.sampleRate
        store.enqueue(sessionID: id, source: .system, pcm16: pcm(samples: firstSamples), presentationTime: time(0))
        _ = try await store.manifest(sessionID: id) // Drain the first packet before the bounded writer queue receives the second.
        store.enqueue(sessionID: id, source: .system, pcm16: pcm(samples: secondSamples), presentationTime: time(Int64(firstSamples)))
        try await store.finish(sessionID: id)
        let manifest = try await store.manifest(sessionID: id)
        XCTAssertEqual(manifest.chunks.count, 2)
        XCTAssertEqual(manifest.chunks.map(\.sampleCount), [300 * AudioRecordingStore.sampleRate, AudioRecordingStore.sampleRate])
        for chunk in manifest.chunks {
            let data = try Data(contentsOf: store.chunkURL(for: chunk, in: manifest))
            XCTAssertEqual(readUInt32(data, 4), UInt32(data.count - 8))
            XCTAssertEqual(readUInt32(data, 40), UInt32(chunk.sampleCount * 2))
            XCTAssertLessThanOrEqual(chunk.durationSeconds, 300)
        }
        try? FileManager.default.removeItem(at: root)
    }

    func testInterruptedRecordingCanBeRecoveredFromPatchedPartialWAV() async throws {
        let (root, store, id) = try makeStore()
        try await store.begin(sessionID: id)
        store.enqueue(sessionID: id, source: .microphone, pcm16: pcm(samples: 2_400), presentationTime: time(0))
        // Queue barrier via manifest read ensures the packet and WAV header landed.
        let beforeRecovery = try await store.manifest(sessionID: id)

        let recovered = try await AudioRecordingStore(rootURL: root).recoverableSessions()
        let manifest = try XCTUnwrap(recovered.first)
        XCTAssertEqual(manifest.id, id)
        XCTAssertFalse(manifest.isComplete)
        XCTAssertEqual(manifest.chunks.first?.sampleCount, 2_400)
        XCTAssertEqual(manifest.expiresAt, beforeRecovery.expiresAt, "Recovery must preserve the originally persisted expiry")
        let wav = try Data(contentsOf: store.chunkURL(for: try XCTUnwrap(manifest.chunks.first), in: manifest))
        XCTAssertEqual(readUInt32(wav, 40), 4_800)
        try? FileManager.default.removeItem(at: root)
    }

    func testRecoveryFlagsAFinishedWAVThatWasTruncatedAfterManifestCommit() async throws {
        let (root, store, id) = try makeStore()
        try await store.begin(sessionID: id)
        store.enqueue(sessionID: id, source: .system, pcm16: pcm(samples: 480), presentationTime: time(0))
        try await store.finish(sessionID: id)
        let committed = try await store.manifest(sessionID: id)
        let wavURL = store.chunkURL(for: try XCTUnwrap(committed.chunks.first), in: committed)
        let handle = try FileHandle(forWritingTo: wavURL)
        try handle.truncate(atOffset: 44 + 240)
        try handle.close()

        let recovered = try await AudioRecordingStore(rootURL: root).recoverableSessions()
        let repaired = try XCTUnwrap(recovered.first)
        XCTAssertFalse(repaired.isComplete)
        XCTAssertEqual(repaired.chunks.first?.sampleCount, 120)
        XCTAssertTrue(repaired.gaps.contains { $0.reason == "finished WAV size differs from saved manifest" })
        try? FileManager.default.removeItem(at: root)
    }

    func testExpiryCleanupDoesNotDeleteAnActiveRecording() async throws {
        let (root, store, id) = try makeStore()
        try await store.begin(sessionID: id)
        try await store.cleanupExpired(now: Date().addingTimeInterval(48 * 60 * 60))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(id.uuidString).path))
        let manifest = try await store.manifest(sessionID: id)
        XCTAssertNil(manifest.finishedAt)
        try? FileManager.default.removeItem(at: root)
    }

    func testExpiryIsMeasuredFromFinishAndRemovesOwnedSessionFolder() async throws {
        let (root, store, id) = try makeStore()
        try await store.begin(sessionID: id)
        try await store.finish(sessionID: id)
        let manifest = try await store.manifest(sessionID: id)
        XCTAssertEqual(manifest.expiresAt.timeIntervalSince(manifest.finishedAt!), 24 * 60 * 60, accuracy: 0.01)
        try await store.cleanupExpired(now: manifest.expiresAt.addingTimeInterval(1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(id.uuidString).path))
        try? FileManager.default.removeItem(at: root)
    }

    func testDiskWriteFailureIsPersistedAsIncomplete() async throws {
        let (root, store, id) = try makeStore()
        try await store.begin(sessionID: id)
        try FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString))
        store.enqueue(sessionID: id, source: .microphone, pcm16: pcm(samples: 240), presentationTime: time(0))
        do { try await store.finish(sessionID: id); XCTFail("expected incomplete recording") }
        catch AudioRecordingError.incompleteRecording { }
        let manifest = try await store.manifest(sessionID: id)
        XCTAssertFalse(manifest.isComplete)
        XCTAssertTrue(manifest.gaps.contains { $0.reason.contains("disk write failed") })
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore() throws -> (URL, AudioRecordingStore, UUID) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-recordings-\(UUID().uuidString)", isDirectory: true)
        return (root, AudioRecordingStore(rootURL: root), UUID())
    }

    private func pcm(samples: Int) -> Data { Data(repeating: 0x2A, count: samples * 2) }
    private func time(_ sample: Int64) -> MediaTime { MediaTime(value: sample, timescale: 24_000) }
    private func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
    }
}
