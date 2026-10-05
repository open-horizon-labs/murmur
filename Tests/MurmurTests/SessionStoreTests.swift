import Foundation
import XCTest
@testable import MurmurApp

final class SessionStoreTests: XCTestCase {
    func testLegacySavedSessionWithoutOptionalPostCallFieldsStillDecodes() throws {
        let legacy = SavedSession(id: UUID(), revision: 4, title: "Before post-call review", transcript: [
            SavedTranscriptEntry(id: "live:1", timestamp: Date(timeIntervalSince1970: 1), text: "Original words", isFinal: true)
        ])
        let encoded = try JSONEncoder().encode(legacy)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in [
            "postCallTranscript", "postCallRevisionID", "postCallStatus", "postCallMessage",
            "postCallModel", "postCallKeepUntilReviewed", "postCallAudioExpiresAt",
            "postCallRecordingIDs", "postCallLiveEntryIDs", "postCallHasCoverageGaps"
        ] { object.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(SavedSession.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.id, legacy.id)
        XCTAssertEqual(decoded.transcript, legacy.transcript)
        XCTAssertNil(decoded.postCallRevisionID)
        XCTAssertNil(decoded.postCallRecordingIDs)
    }

    func testRoundTripAcrossStoreInstancesAndRejectsStaleRevision() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let original = makeSession(id: id, revision: 1, title: "First")
        let updated = makeSession(id: id, revision: 2, title: "Updated")
        let firstStore = LocalSessionStore(directoryURL: directory)
        try await firstStore.save(original)

        // A distinct actor/store instance must observe the on-disk revision too.
        let secondStore = LocalSessionStore(directoryURL: directory)
        try await secondStore.save(updated)
        do {
            try await firstStore.save(original)
            XCTFail("Expected a stale revision to be rejected")
        } catch let error as SessionStoreError {
            guard case .staleRevision(let staleID, let incoming, let latest) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(staleID, id)
            XCTAssertEqual(incoming, 1)
            XCTAssertEqual(latest, 2)
        }

        let recovered = try await LocalSessionStore(directoryURL: directory).load(id: id)
        XCTAssertEqual(recovered.session, updated)
        XCTAssertFalse(recovered.recoveredFromBackup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL(directory, id).path))
    }

    func testCorruptPrimaryRecoversBackupAndLaterSavePreservesGoodBackup() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let store = LocalSessionStore(directoryURL: directory)
        let first = makeSession(id: id, revision: 1, title: "Good backup")
        try await store.save(first)
        try await store.save(makeSession(id: id, revision: 2, title: "New primary"))
        let knownGoodBackup = try Data(contentsOf: backupURL(directory, id))
        try Data("broken json".utf8).write(to: primaryURL(directory, id), options: .atomic)

        let result = try await store.load(id: id)
        XCTAssertEqual(result.session, first)
        XCTAssertTrue(result.recoveredFromBackup)

        try await store.save(makeSession(id: id, revision: 2, title: "Edited from recovered backup"))
        XCTAssertEqual(try Data(contentsOf: backupURL(directory, id)), knownGoodBackup)
        let afterSave = try await LocalSessionStore(directoryURL: directory).load(id: id)
        XCTAssertEqual(afterSave.session.title, "Edited from recovered backup")
        XCTAssertEqual(afterSave.session.revision, 2)
        XCTAssertFalse(afterSave.recoveredFromBackup)
    }

    func testFutureSchemaWithUnknownEnvelopeIsNeverDecodedAsCorruptOrOverwritten() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let url = primaryURL(directory, id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let future = Data("{\"schemaVersion\":2,\"newPayload\":{\"anything\":true}}".utf8)
        try future.write(to: url)
        let store = LocalSessionStore(directoryURL: directory)

        do {
            _ = try await store.load(id: id)
            XCTFail("Expected an explicit unsupported-schema error")
        } catch let error as SessionStoreError {
            guard case .unsupportedSchemaVersion(_, 2) = error else { return XCTFail("Unexpected error: \(error)") }
        }
        do {
            try await store.save(makeSession(id: id, revision: 100))
            XCTFail("Expected future data to block overwrite")
        } catch let error as SessionStoreError {
            guard case .unsupportedSchemaVersion(_, 2) = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: url), future)
        let listing = try await store.list()
        XCTAssertEqual(listing.count, 1)
        XCTAssertFalse(listing[0].available)
        XCTAssertNotNil(listing[0].warning)
    }

    func testListKeepsHealthyRowsAndShowsCorruptAndBackupOnlyRows() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = LocalSessionStore(directoryURL: directory)
        let healthy = makeSession(id: UUID(), revision: 1, title: "Healthy")
        let backedUp = makeSession(id: UUID(), revision: 1, title: "Backup only")
        try await store.save(healthy)
        try await store.save(backedUp)
        try await store.save(makeSession(id: backedUp.id, revision: 2, title: "Primary removed"))
        try FileManager.default.removeItem(at: primaryURL(directory, backedUp.id))

        let corruptID = UUID()
        try Data("not-json".utf8).write(to: primaryURL(directory, corruptID))
        let summaries = try await LocalSessionStore(directoryURL: directory).list()
        XCTAssertEqual(Set(summaries.map(\.id)), Set([healthy.id, backedUp.id, corruptID]))
        XCTAssertTrue(summaries.first(where: { $0.id == healthy.id })?.available == true)
        XCTAssertEqual(summaries.first(where: { $0.id == backedUp.id })?.title, "Backup only")
        XCTAssertTrue(summaries.first(where: { $0.id == backedUp.id })?.warning?.contains("backup") == true)
        XCTAssertFalse(summaries.first(where: { $0.id == corruptID })?.available ?? true)
    }

    func testDeleteTombstonePreventsDelayedSaveFromAnotherStoreAndSurvivesRestart() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let staleStore = LocalSessionStore(directoryURL: directory)
        try await staleStore.save(makeSession(id: id, revision: 1, title: "Will be deleted"))
        try await LocalSessionStore(directoryURL: directory).delete(id: id)

        do {
            try await staleStore.save(makeSession(id: id, revision: 2, title: "Stale queued save"))
            XCTFail("Expected tombstone to reject a delayed writer")
        } catch let error as SessionStoreError {
            guard case .deleted(let deletedID) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(deletedID, id)
        }
        do {
            _ = try await LocalSessionStore(directoryURL: directory).load(id: id)
            XCTFail("Deleted data must remain deleted after creating a new store")
        } catch let error as SessionStoreError {
            guard case .deleted = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let afterDelete = try await LocalSessionStore(directoryURL: directory).list()
        XCTAssertTrue(afterDelete.isEmpty)
    }

    func testFailedDeleteLeavesRetryWarningAndDoesNotClaimSuccess() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let session = makeSession(id: id, revision: 1)
        let blockedURL = primaryURL(directory, id)
        let store = LocalSessionStore(directoryURL: directory, fileRemover: { url in
            if url == blockedURL { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: url)
        })
        try await store.save(session)
        do {
            try await store.delete(id: id)
            XCTFail("Expected the injected removal failure to propagate")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: blockedURL.path))
        }
        let pending = try await LocalSessionStore(directoryURL: directory).list()
        XCTAssertEqual(pending.count, 1)
        XCTAssertFalse(pending[0].available)
        XCTAssertTrue(pending[0].warning?.contains("retry Delete") == true)

        try await LocalSessionStore(directoryURL: directory).delete(id: id)
        let afterRetry = try await LocalSessionStore(directoryURL: directory).list()
        XCTAssertTrue(afterRetry.isEmpty)
    }

    func testUnreadableFileIOIsNotTreatedAsCorruptionDuringSave() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = primaryURL(directory, id)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        do {
            try await LocalSessionStore(directoryURL: directory).save(makeSession(id: id, revision: 1))
            XCTFail("Expected a read error for the directory used as the record file")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: nil))
        }
    }

    func testVersionOneFixtureDecodesWhenOptionalProvenanceIsAbsent() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let fixture = """
        {
          "schemaVersion": 1,
          "id": "\(id.uuidString)",
          "revision": 1,
          "title": "Old version one record",
          "createdAt": 1000,
          "updatedAt": 1001,
          "workspaceName": "Fixture",
          "isDemo": false,
          "sourceMode": "Microphone",
          "transcriptionModel": "gpt-live-transcribe",
          "contextModel": "gpt-5.6-luna",
          "investigationModel": "gpt-5.6-sol",
          "transcript": [{"id":"entry","timestamp":999,"text":"Fixture text","isFinal":true}],
          "context": null,
          "investigations": []
        }
        """
        try Data(fixture.utf8).write(to: primaryURL(directory, id))

        let loaded = try await LocalSessionStore(directoryURL: directory).load(id: id)
        XCTAssertNil(loaded.session.contextFindingModel)
        XCTAssertNil(loaded.session.contextUpdatedAt)
        XCTAssertEqual(loaded.session.transcript.first?.text, "Fixture text")
    }

    func testLargeTranscriptAndExportRetainCompleteEvidenceAndPassageData() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let finding = SavedFinding(
            id: "finding",
            title: "Source result",
            summary: "The implementation checks the limit.",
            evidence: [AgentEvidence(path: "Sources/Retry.swift", lineStart: 18, lineEnd: 21, excerpt: "maximumAttempts = 4")],
            confidence: 0.9,
            skillsUsed: ["code-search"],
            tier: AgentTier.deep.rawValue
        )
        let transcript = (0..<10_000).map { index in
            SavedTranscriptEntry(id: "item-\(index)", timestamp: timestamp.addingTimeInterval(Double(index)), text: "Transcript sentence \(index)", isFinal: index % 10 != 0)
        }
        let investigation = SavedInvestigation(
            id: UUID(), selectionText: "We decided to increase the retry limit.", entryIDs: ["item-9999"],
            question: "What does the code enforce?", status: "completed", statusMessage: "Finished",
            finding: finding, model: "gpt-5.6-sol", createdAt: timestamp
        )
        let session = makeSession(
            id: UUID(), revision: 5, title: "Large saved conversation",
            transcript: transcript, context: finding, investigations: [investigation]
        )
        let store = LocalSessionStore(directoryURL: directory)
        try await store.save(session)
        let reloaded = try await LocalSessionStore(directoryURL: directory).load(id: session.id).session
        XCTAssertEqual(reloaded.transcript.count, 10_000)
        XCTAssertEqual(reloaded.transcript.last?.text, "Transcript sentence 9999")
        XCTAssertEqual(reloaded.investigations.first?.selectionText, investigation.selectionText)
        XCTAssertEqual(reloaded.context?.evidence.first?.excerpt, "maximumAttempts = 4")

        let json = String(decoding: try SessionExporter.data(session: reloaded, format: .json), as: UTF8.self)
        let markdown = String(decoding: try SessionExporter.data(session: reloaded, format: .markdown), as: UTF8.self)
        XCTAssertTrue(json.contains("item-9999"))
        XCTAssertTrue(json.contains("maximumAttempts = 4"))
        XCTAssertTrue(markdown.contains("Transcript sentence 9999"))
        XCTAssertTrue(markdown.contains("What does the code enforce?"))
        XCTAssertTrue(markdown.contains("Sources/Retry.swift"))
        XCTAssertTrue(markdown.contains("maximumAttempts = 4"))
        XCTAssertFalse(markdown.contains("confidence"))
        XCTAssertFalse(markdown.contains("item-9999"))
        XCTAssertEqual(SessionExporter.fileExtension(for: .markdown), "md")
        XCTAssertEqual(SessionExporter.fileExtension(for: .json), "json")
    }

    func testSnapshotSaveLoadAndHistoryListingStayResponsive() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let transcript = (0..<10_000).map { index in
            SavedTranscriptEntry(id: "entry-\(index)", timestamp: timestamp, text: "A short meeting utterance number \(index).", isFinal: true)
        }
        let snapshot = makeSession(id: UUID(), revision: 1, title: "10k transcript", transcript: transcript)
        let store = LocalSessionStore(directoryURL: directory)
        let clock = ContinuousClock()

        let saveStart = clock.now
        try await store.save(snapshot)
        let saveDuration = saveStart.duration(to: clock.now)
        let loadStart = clock.now
        let loaded = try await LocalSessionStore(directoryURL: directory).load(id: snapshot.id)
        let loadDuration = loadStart.duration(to: clock.now)
        XCTAssertEqual(loaded.session.transcript.count, 10_000)

        let listStore = LocalSessionStore(directoryURL: directory)
        let listStart = clock.now
        for index in 0..<100 {
            try await listStore.save(makeSession(id: UUID(), revision: 1, title: "History row \(index)"))
        }
        let listed = try await LocalSessionStore(directoryURL: directory).list()
        let listDuration = listStart.duration(to: clock.now)
        XCTAssertEqual(listed.count, 101)
        XCTAssertTrue(saveDuration < .seconds(15), "10k-entry save took \(saveDuration)")
        XCTAssertTrue(loadDuration < .seconds(15), "10k-entry load took \(loadDuration)")
        XCTAssertTrue(listDuration < .seconds(15), "Listing 101 saved sessions took \(listDuration)")
        print("Session store timings: save 10k=\(saveDuration), load 10k=\(loadDuration), save+list 101=\(listDuration)")
    }

    func testRuntimeDTOConversionsPreserveInvestigationState() {
        let runtimeFinding = AgentFinding(
            id: "finding-id", title: "Finding", summary: "Summary",
            evidence: [AgentEvidence(path: "a.swift", lineStart: 1, lineEnd: 2, excerpt: "source")],
            confidence: 0.75, skillsUsed: ["search"], tier: .deep
        )
        let runtimeInvestigation = PassageInvestigation(
            id: UUID(), selection: TranscriptSelection(text: "exact quote", entryIDs: ["entry-1"]),
            question: "Check the claim", activity: .failed("No match"), finding: runtimeFinding
        )
        let saved = SavedInvestigation(runtimeInvestigation, model: "model", createdAt: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(saved.passageInvestigation, runtimeInvestigation)
        XCTAssertEqual(saved.finding?.agentFinding, runtimeFinding)
    }

    private func makeSession(
        id: UUID,
        revision: Int,
        title: String = "Test session",
        transcript: [SavedTranscriptEntry] = [],
        context: SavedFinding? = nil,
        investigations: [SavedInvestigation] = []
    ) -> SavedSession {
        SavedSession(
            id: id,
            revision: revision,
            title: title,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            workspacePath: "/workspace",
            workspaceName: "Example",
            isDemo: false,
            sourceMode: AudioSourceMode.microphone.rawValue,
            transcriptionModel: TranscriptionModel.live.rawValue,
            contextModel: "context-model",
            investigationModel: "investigation-model",
            transcript: transcript,
            context: context,
            contextUpdatedAt: context == nil ? nil : Date(timeIntervalSince1970: 1_700_000_050),
            transcriptRevision: transcript.count,
            contextTranscriptRevision: context == nil ? nil : 7,
            contextFindingModel: context == nil ? nil : "model-used-for-context",
            investigations: investigations
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SessionStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func primaryURL(_ directory: URL, _ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func backupURL(_ directory: URL, _ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).backup.json")
    }
}
