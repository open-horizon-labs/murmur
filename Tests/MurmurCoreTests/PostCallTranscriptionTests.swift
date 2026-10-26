import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MurmurCore

final class PostCallTranscriptionTests: XCTestCase {
    func testMixedWindowsPreserveGlobalOrderAndOverlappingSourceAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let started = Date(timeIntervalSince1970: 1_000)
        let system0 = chunk(.system, offset: 0, samples: [4_000, 4_000, 4_000, 4_000, 1], name: "sys0.wav")
        let mic0 = chunk(.microphone, offset: 0, samples: [8_000, 8_000, 0, 0], name: "mic0.wav")
        let mic1 = chunk(.microphone, offset: 301, samples: [6_000, 6_000], name: "mic1.wav")
        let chunks = [system0, mic0, mic1]
        let audio: [(AudioRecordingChunk, [Int16])] = [
            (system0, [4_000, 4_000, 4_000, 4_000, 1]), (mic0, [8_000, 8_000, 0, 0]), (mic1, [6_000, 6_000])
        ]
        for (item, values) in audio {
            try makeWAV(values).write(to: root.appendingPathComponent(item.relativePath))
        }
        let manifest = manifest(started: started, chunks: chunks)
        let batch = InspectingBatchTranscriber()
        let coordinator = PostCallTranscriptionCoordinator(transcriber: batch, checkpointStore: MemoryCheckpointStore())

        let result = try await coordinator.transcribe(
            manifest: manifest, sessionID: manifest.id,
            chunkURL: { root.appendingPathComponent($0.relativePath) }, model: "provider/custom-batch-model"
        )

        XCTAssertEqual(result.entries.map(\.text), ["window 1", "window 2"])
        XCTAssertEqual(result.entries.map(\.timestamp), [started, started.addingTimeInterval(301)])
        XCTAssertEqual(Set(result.completedChunkIDs), Set(chunks.map(\.id)))
        let samples = await batch.firstWindowSamples
        XCTAssertEqual(samples[0], 6_000) // mean of simultaneous 4,000 and 8,000 sources
        XCTAssertEqual(samples[1], 4_000) // silent microphone does not attenuate system audio
        XCTAssertEqual(samples[2], 1) // quiet samples are retained without a denoising threshold
        let receivedModels = await batch.receivedModels
        XCTAssertEqual(receivedModels, ["provider/custom-batch-model", "provider/custom-batch-model"])
        let wavSizes = await batch.receivedWavSizes
        XCTAssertEqual(wavSizes, [54, 48], "Each WAV is trimmed to the actual final frame instead of padded to five minutes.")
    }

    func testUnknownOutcomeIsNeverRetriedWithoutExplicitUserChoice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let item = chunk(.system, offset: 0, samples: [2_000, 2_000], name: "source.wav")
        try makeWAV([2_000, 2_000]).write(to: root.appendingPathComponent(item.relativePath))
        let manifest = manifest(started: Date(timeIntervalSince1970: 1_000), chunks: [item])
        let store = MemoryCheckpointStore()
        let batch = InspectingBatchTranscriber(failFirstRequest: true)
        let coordinator = PostCallTranscriptionCoordinator(transcriber: batch, checkpointStore: store)
        let lookup: @Sendable (AudioRecordingChunk) async throws -> URL = { root.appendingPathComponent($0.relativePath) }

        do {
            _ = try await coordinator.transcribe(manifest: manifest, sessionID: manifest.id, chunkURL: lookup, model: "gpt-transcribe")
            XCTFail("expected uncertain transport failure")
        } catch InspectingBatchTranscriber.Failure.unknownOutcome { }
        do {
            _ = try await coordinator.transcribe(manifest: manifest, sessionID: manifest.id, chunkURL: lookup, model: "gpt-transcribe")
            XCTFail("expected guard against an automatic duplicate request")
        } catch PostCallTranscriptionError.uncertainPriorRequest { }
        let firstRequestCount = await batch.requestCount
        XCTAssertEqual(firstRequestCount, 1)

        let retried = try await coordinator.transcribe(
            manifest: manifest, sessionID: manifest.id, chunkURL: lookup,
            model: "gpt-transcribe", allowRetryUncertain: true
        )
        XCTAssertEqual(retried.entries.count, 1)
        let finalRequestCount = await batch.requestCount
        XCTAssertEqual(finalRequestCount, 2)
    }

    func testCancellationLeavesCheckpointForExplicitRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let item = chunk(.system, offset: 0, samples: [1, 1], name: "source.wav")
        try makeWAV([1, 1]).write(to: root.appendingPathComponent(item.relativePath))
        let manifest = manifest(started: Date(), chunks: [item])
        let batch = SlowBatchTranscriber()
        let coordinator = PostCallTranscriptionCoordinator(transcriber: batch, checkpointStore: MemoryCheckpointStore())
        let lookup: @Sendable (AudioRecordingChunk) async throws -> URL = { root.appendingPathComponent($0.relativePath) }
        let request = Task { try await coordinator.transcribe(manifest: manifest, sessionID: manifest.id, chunkURL: lookup, model: "gpt-transcribe") }
        for _ in 0..<100 {
            if await batch.requestCount > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        request.cancel()
        do { _ = try await request.value; XCTFail("expected cancellation") }
        catch is CancellationError { }
        do {
            _ = try await coordinator.transcribe(manifest: manifest, sessionID: manifest.id, chunkURL: lookup, model: "gpt-transcribe")
            XCTFail("cancellation must not trigger a duplicate upload")
        } catch PostCallTranscriptionError.uncertainPriorRequest { }
        let count = await batch.requestCount
        XCTAssertEqual(count, 1)
    }

    func testLongWindowTextIsSplitWithoutLossAndFullyReadable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let item = chunk(.system, offset: 0, samples: [1, 1], name: "source.wav")
        try makeWAV([1, 1]).write(to: root.appendingPathComponent(item.relativePath))
        let manifest = manifest(started: Date(), chunks: [item])
        let fullText = String(repeating: "•🗓", count: 3_000)
        let batch = FixedBatchTranscriber(text: fullText)
        let coordinator = PostCallTranscriptionCoordinator(transcriber: batch, checkpointStore: MemoryCheckpointStore())
        let entries = try await coordinator.transcribe(
            manifest: manifest, sessionID: manifest.id,
            chunkURL: { root.appendingPathComponent($0.relativePath) }, model: "gpt-transcribe"
        ).entries
        XCTAssertGreaterThan(entries.count, 1)
        XCTAssertTrue(entries.allSatisfy { $0.text.utf8.count <= 3_000 })
        XCTAssertEqual(entries.map(\.text).joined(), fullText)
        XCTAssertEqual(Set(entries.map(\.timestamp)).count, 1, "Provider text has no finer timestamp evidence.")
        let snapshot = CallContextSnapshot(sessionID: manifest.id, revision: 1, entries: entries, workspace: nil)
        let tools = CallTranscriptTools(snapshot: snapshot)
        let output = try await tools.execute(name: "read_call_transcript", arguments: "{\"offset\":0,\"limit\":24}")
        for entry in entries { XCTAssertTrue(output.contains(entry.text)) }
        let remainingCoverage = await tools.remainingFinalReadCount()
        XCTAssertEqual(remainingCoverage, 0)
    }

    func testTruncatedChunkCannotPassManifestSampleCountValidation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let item = chunk(.microphone, offset: 0, samples: [1, 2, 3, 4], name: "truncated.wav")
        try makeWAV([1, 2]).write(to: root.appendingPathComponent(item.relativePath))
        let manifest = manifest(started: Date(), chunks: [item])
        let batch = InspectingBatchTranscriber()
        let coordinator = PostCallTranscriptionCoordinator(transcriber: batch, checkpointStore: MemoryCheckpointStore())
        do {
            _ = try await coordinator.transcribe(
                manifest: manifest, sessionID: manifest.id,
                chunkURL: { root.appendingPathComponent($0.relativePath) }, model: "gpt-transcribe"
            )
            XCTFail("A truncated WAV cannot silently reduce audio coverage.")
        } catch PostCallTranscriptionError.invalidManifest { }
        let requestCount = await batch.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    func testOpenAIMultipartPassesArbitraryModelAndWAVFilename() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("call audio.wav")
        try makeWAV([1, 2, 3]).write(to: file)
        URLProtocolStub.install { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            XCTAssertTrue(body.contains("name=\"model\"\r\n\r\norg/private-transcription-model"))
            XCTAssertTrue(body.contains("filename=\"call audio.wav\""))
            XCTAssertTrue(body.contains("name=\"response_format\"\r\n\r\njson"))
            let payload = try JSONSerialization.data(withJSONObject: ["text": "Monday is not the release day."])
            return (200, payload)
        }
        defer { URLProtocolStub.clear() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        let client = OpenAIBatchAudioTranscriber(session: URLSession(configuration: config), apiKey: { "fixture" })
        let result = try await client.transcribe(fileURL: file, fileName: file.lastPathComponent, model: "org/private-transcription-model")
        XCTAssertEqual(result.text, "Monday is not the release day.")
        XCTAssertTrue(result.segments.isEmpty)
    }

    func testOversizedUploadIsRejectedBeforeNetwork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large.wav")
        var wav = makeWAV([1])
        wav.append(Data(repeating: 0, count: 25 * 1024 * 1024))
        try wav.write(to: file)
        let client = OpenAIBatchAudioTranscriber(apiKey: { XCTFail("must fail before loading credentials"); return "" })
        do {
            _ = try await client.transcribe(fileURL: file, fileName: "large.wav", model: "gpt-transcribe")
            XCTFail("expected size rejection")
        } catch OpenAIBatchTranscriptionError.fileTooLarge { }
    }

    func testOptInLiveSyntheticFixturePreservesCorrectionsAndNegativeStatements() async throws {
        guard let fixturePath = ProcessInfo.processInfo.environment["MURMUR_POSTCALL_FIXTURE"],
              FileManager.default.fileExists(atPath: fixturePath) else {
            throw XCTSkip("Set MURMUR_POSTCALL_FIXTURE to the generated synthetic known-call.wav to run the billable provider smoke.")
        }
        guard let batchModel = ProcessInfo.processInfo.environment["MURMUR_POSTCALL_MODEL"], !batchModel.isEmpty,
              let contextModel = ProcessInfo.processInfo.environment["MURMUR_POSTCALL_CONTEXT_MODEL"], !contextModel.isEmpty else {
            throw XCTSkip("Set MURMUR_POSTCALL_MODEL and MURMUR_POSTCALL_CONTEXT_MODEL explicitly for this paid test.")
        }
        let keyProvider = await MainActor.run {
            OpenAIAPIKeyProvider(credentialStore: EmptyTranscriptionCredentialStore(), environmentKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"])
        }
        let transcriber = OpenAIBatchAudioTranscriber(apiKey: { try await MainActor.run { try keyProvider.load() } })
        let fixture = URL(fileURLWithPath: fixturePath)
        let sampleCount = try wavSampleCount(fixture)
        let recordingRoot = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-live-postcall-\(UUID().uuidString)", isDirectory: true)
        let recordingID = UUID()
        let recordingFolder = recordingRoot.appendingPathComponent(recordingID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: recordingFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: recordingRoot) }
        let recordingURL = recordingFolder.appendingPathComponent("known-call.wav")
        try FileManager.default.copyItem(at: fixture, to: recordingURL)
        let capture = AudioRecordingManifest(
            id: recordingID, expectedSources: [.system], createdAt: Date(),
            expiresAt: Date().addingTimeInterval(86_400), finishedAt: Date(), isComplete: true,
            chunks: [AudioRecordingChunk(id: UUID(), source: .system, relativePath: recordingURL.lastPathComponent,
                                         offsetSeconds: 0, durationSeconds: Double(sampleCount) / 24_000, sampleCount: sampleCount)],
            gaps: [], analysisSavedAt: nil
        )
        try JSONEncoder().encode(capture).write(to: recordingFolder.appendingPathComponent("manifest.json"), options: .atomic)
        let checkpointStore = JSONPostCallTranscriptionCheckpointStore(directory: recordingRoot)
        let conversationID = UUID()
        let coordinator = PostCallTranscriptionCoordinator(transcriber: transcriber, checkpointStore: checkpointStore)
        let batchResult = try await coordinator.transcribe(
            manifest: capture, sessionID: recordingID, transcriptSessionID: conversationID,
            chunkURL: { _ in recordingURL }, model: batchModel
        )
        let text = batchResult.entries.map(\.text).joined().lowercased()
        XCTAssertTrue((text.contains("eight") || text.contains("8")) && (text.contains("ten") || text.contains("10")), text)
        XCTAssertTrue(text.contains("load test"), text)
        XCTAssertTrue(text.contains("tuesday") && text.contains("weekly"), text)
        XCTAssertTrue(text.contains("unless"), text)
        XCTAssertTrue(containsWeeklyCancellation(text), text)
        XCTAssertTrue(containsContrast(text, first: "monday", negation: "not", second: "friday"), text)
        XCTAssertTrue(text.contains("cloudflare") && text.contains("pending"), text)
        XCTAssertTrue(containsNegatedPhrase(text, negation: "not", phrase: "production access"), text)

        let artifact = fixture.deletingLastPathComponent().appendingPathComponent("known-call-transcription.json")
        let artifactData = try JSONSerialization.data(withJSONObject: ["model": batchModel, "transcript": batchResult.entries.map(\.text).joined()], options: [.prettyPrinted, .sortedKeys])
        try artifactData.write(to: artifact, options: .atomic)

        let contextAgent = OpenAIConversationAgent(apiKeyProvider: { try await MainActor.run { try keyProvider.load() } })
        let finding = try await contextAgent.updateContext(
            snapshot: CallContextSnapshot(sessionID: conversationID, revision: 2, entries: batchResult.entries, workspace: nil, isFinalReview: true),
            previous: nil, model: contextModel
        )
        let contextArtifact = fixture.deletingLastPathComponent().appendingPathComponent("known-call-context.json")
        let evidenceArtifact = finding.evidence.map {
            ["path": $0.path, "excerpt": $0.excerpt, "sessionID": $0.transcriptSessionID ?? "", "entryID": $0.transcriptEntryID ?? ""]
        }
        let contextArtifactData = try JSONSerialization.data(withJSONObject: ["model": contextModel, "title": finding.title, "summary": finding.summary, "evidence": evidenceArtifact], options: [.prettyPrinted, .sortedKeys])
        try contextArtifactData.write(to: contextArtifact, options: .atomic)
        for heading in ["Summary", "Actions", "Open questions"] {
            XCTAssertTrue(finding.summary.localizedCaseInsensitiveContains(heading), finding.summary)
        }
        XCTAssertTrue(finding.summary.localizedCaseInsensitiveContains("Monday"), finding.summary)
        XCTAssertFalse(batchResult.entries.contains(where: { finding.summary.contains($0.id) }), finding.summary)
        let entryIDs = Set(batchResult.entries.map(\.id))
        XCTAssertTrue(finding.evidence.contains { evidence in
            guard evidence.transcriptSessionID == conversationID.uuidString,
                  let id = evidence.transcriptEntryID, entryIDs.contains(id),
                  let entry = batchResult.entries.first(where: { $0.id == id }) else { return false }
            return entry.text.contains(evidence.excerpt)
        }, "Final Context must cite exact inspected text from this synthetic transcript.")

        let resumedCoordinator = PostCallTranscriptionCoordinator(transcriber: NeverBatchTranscriber(), checkpointStore: JSONPostCallTranscriptionCheckpointStore(directory: recordingRoot))
        let resumed = try await resumedCoordinator.transcribe(
            manifest: capture, sessionID: recordingID, transcriptSessionID: conversationID,
            chunkURL: { _ in recordingURL }, model: batchModel
        )
        XCTAssertEqual(resumed.entries, batchResult.entries)

        let sessionsDirectory = recordingRoot.appendingPathComponent("sessions", isDirectory: true)
        let sessions = LocalSessionStore(directoryURL: sessionsDirectory)
        let saved = SavedSession(
            id: conversationID, title: "Synthetic post-call check", transcriptionModel: batchModel,
            contextModel: contextModel, transcript: batchResult.entries.map(SavedTranscriptEntry.init),
            context: SavedFinding(finding), contextUpdatedAt: Date(), transcriptRevision: 2,
            contextTranscriptRevision: 2, contextFindingModel: contextModel
        )
        try await sessions.save(saved)
        let reopened = try await LocalSessionStore(directoryURL: sessionsDirectory).load(id: conversationID).session
        XCTAssertEqual(reopened.transcript, saved.transcript)
        XCTAssertEqual(reopened.context, saved.context)
        let checkpoint = try await checkpointStore.load(sessionID: recordingID)
        XCTAssertEqual(checkpoint?.model, batchModel)
        XCTAssertEqual(checkpoint?.completedWindows.count, 1)
    }

    private func wavSampleCount(_ url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        var offset = 12
        while offset + 8 <= data.count {
            let tag = String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
            let length = Int(UInt32(data[offset + 4]) | UInt32(data[offset + 5]) << 8 | UInt32(data[offset + 6]) << 16 | UInt32(data[offset + 7]) << 24)
            let payload = offset + 8
            guard length >= 0, payload + length <= data.count else { break }
            if tag == "data" { return length / 2 }
            offset = payload + length + (length & 1)
        }
        throw OpenAIBatchTranscriptionError.invalidAudioFile
    }

    private func containsContrast(_ text: String, first: String, negation: String, second: String) -> Bool {
        guard let firstRange = text.range(of: first) else { return false }
        let tail = String(text[firstRange.upperBound...].prefix(60))
        return tail.contains(negation) && tail.contains(second)
    }

    private func containsNegatedPhrase(_ text: String, negation: String, phrase: String) -> Bool {
        guard let phraseRange = text.range(of: phrase) else { return false }
        let head = String(text[..<phraseRange.lowerBound].suffix(60))
        return head.contains(negation)
    }

    private func containsWeeklyCancellation(_ text: String) -> Bool {
        guard let range = text.range(of: "weekly") else { return false }
        let start = text.index(range.lowerBound, offsetBy: -min(80, text.distance(from: text.startIndex, to: range.lowerBound)), limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: min(80, text.distance(from: range.upperBound, to: text.endIndex)), limitedBy: text.endIndex) ?? text.endIndex
        let context = String(text[start..<end])
        let denied = ["not need", "do not need", "don't need", "no need", "not necessary", "unnecessary", "no weekly"]
        return denied.contains(where: context.contains) && context.contains("call") && context.contains("unless")
    }

    private func manifest(started: Date, chunks: [AudioRecordingChunk]) -> AudioRecordingManifest {
        AudioRecordingManifest(
            id: UUID(), expectedSources: Set(chunks.map(\.source)), createdAt: started,
            expiresAt: Date().addingTimeInterval(86_400), finishedAt: started, isComplete: true,
            chunks: chunks, gaps: [], analysisSavedAt: nil
        )
    }

    private func chunk(_ source: AudioRecordingSource, offset: Double, samples: [Int16], name: String) -> AudioRecordingChunk {
        AudioRecordingChunk(id: UUID(), source: source, relativePath: name, offsetSeconds: offset,
                            durationSeconds: Double(samples.count) / 24_000, sampleCount: samples.count)
    }

    private func makeWAV(_ samples: [Int16]) -> Data {
        var data = Data()
        func u16(_ value: UInt16) { data.append(UInt8(value & 0xff)); data.append(UInt8(value >> 8)) }
        func u32(_ value: UInt32) { u16(UInt16(value & 0xffff)); u16(UInt16(value >> 16)) }
        data.append(contentsOf: "RIFF".utf8); u32(UInt32(36 + samples.count * 2)); data.append(contentsOf: "WAVEfmt ".utf8)
        u32(16); u16(1); u16(1); u32(24_000); u32(48_000); u16(2); u16(16)
        data.append(contentsOf: "data".utf8); u32(UInt32(samples.count * 2))
        for sample in samples { u16(UInt16(bitPattern: sample)) }
        return data
    }
}

private actor MemoryCheckpointStore: PostCallTranscriptionCheckpointStoring {
    private var value: PostCallTranscriptionCheckpoint?
    func load(sessionID: UUID) -> PostCallTranscriptionCheckpoint? { value?.sessionID == sessionID ? value : nil }
    func save(_ checkpoint: PostCallTranscriptionCheckpoint) { value = checkpoint }
}

private actor InspectingBatchTranscriber: BatchAudioTranscribing {
    enum Failure: Error { case unknownOutcome }
    private var count = 0
    private var models: [String] = []
    private var samples: [Int] = []
    private var wavSizes: [Int] = []
    private let failFirst: Bool

    init(failFirstRequest: Bool = false) { failFirst = failFirstRequest }

    var requestCount: Int { count }
    var receivedModels: [String] { models }
    var firstWindowSamples: [Int] { samples }
    var receivedWavSizes: [Int] { wavSizes }

    func transcribe(fileURL: URL, fileName: String, model: String) async throws -> PostCallBatchTranscript {
        count += 1
        models.append(model)
        let wav = try Data(contentsOf: fileURL)
        wavSizes.append(wav.count)
        XCTAssertEqual(wav.prefix(4), Data("RIFF".utf8))
        if count == 1, wav.count > 50 {
            samples = [sample(wav, frame: 0), sample(wav, frame: 2), sample(wav, frame: 4)]
        }
        if failFirst, count == 1 { throw Failure.unknownOutcome }
        return PostCallBatchTranscript(text: "window \(count)")
    }

    private func sample(_ data: Data, frame: Int) -> Int {
        let offset = 44 + frame * 2
        return Int(Int16(bitPattern: UInt16(data[offset]) | UInt16(data[offset + 1]) << 8))
    }
}

private actor SlowBatchTranscriber: BatchAudioTranscribing {
    private(set) var requestCount = 0
    func transcribe(fileURL: URL, fileName: String, model: String) async throws -> PostCallBatchTranscript {
        requestCount += 1
        try await Task.sleep(for: .seconds(60))
        return PostCallBatchTranscript(text: "unreachable")
    }
}

private actor FixedBatchTranscriber: BatchAudioTranscribing {
    private let text: String
    init(text: String) { self.text = text }
    func transcribe(fileURL: URL, fileName: String, model: String) -> PostCallBatchTranscript {
        PostCallBatchTranscript(text: text)
    }
}

private struct NeverBatchTranscriber: BatchAudioTranscribing {
    enum Failure: Error { case checkpointWasNotUsed }
    func transcribe(fileURL: URL, fileName: String, model: String) async throws -> PostCallBatchTranscript {
        throw Failure.checkpointWasNotUsed
    }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) throws -> (Int, Data)
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var handler: Handler?
    }
    private static let state = State()

    static func install(_ handler: @escaping Handler) { state.lock.lock(); state.handler = handler; state.lock.unlock() }
    static func clear() { state.lock.lock(); state.handler = nil; state.lock.unlock() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.state.lock.lock(); let handler = Self.state.handler; Self.state.lock.unlock()
        do {
            guard let handler else { throw URLError(.badServerResponse) }
            var completeRequest = request
            if completeRequest.httpBody == nil, let stream = completeRequest.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var body = Data()
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 8_192)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let count = stream.read(buffer, maxLength: 8_192)
                    if count <= 0 { break }
                    body.append(buffer, count: count)
                }
                completeRequest.httpBody = body
            }
            let (status, data) = try handler(completeRequest)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
