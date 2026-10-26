import XCTest
@testable import MurmurCore

/// Opt-in live exercise for transcript search, paraphrased question handling,
/// full-call correction retrieval, and stable call evidence validation.
final class LiveCallSnapshotTests: XCTestCase {
    func testLiveCallFindsMidstreamCorrectionFromFullSnapshot() async throws {
        guard ProcessInfo.processInfo.environment["MURMUR_LIVE_CALL_TEST"] == "1",
              let model = ProcessInfo.processInfo.environment["MURMUR_LIVE_API_MODEL"], !model.isEmpty else {
            throw XCTSkip("Set MURMUR_LIVE_CALL_TEST=1 and MURMUR_LIVE_API_MODEL to your chosen model to run this paid live test.")
        }
        let key = try ProcessInfo.processInfo.environment["OPENAI_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
            ?? EmptyTranscriptionCredentialStore().load()
        guard let key, !key.isEmpty else { throw XCTSkip("An API key is required in OPENAI_API_KEY or the (the macOS Keychain fallback is not available in MurmurCore tests).") }

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var entries = (0..<55).map { index in
            TranscriptEntry(id: "live-\(index)", timestamp: start.addingTimeInterval(Double(index) * 60), text: "Unrelated planning detail number \(index).", isFinal: true)
        }
        entries[2] = TranscriptEntry(id: "early-plan", timestamp: start, text: "Initial plan: schedule the launch for Friday.", isFinal: true)
        entries[4] = TranscriptEntry(id: "spoken-guarantee", timestamp: start.addingTimeInterval(4 * 60), text: "The speaker claims our controller is guaranteed never to fail under any load.", isFinal: true)
        entries[30] = TranscriptEntry(id: "mid-correction", timestamp: start.addingTimeInterval(45 * 60), text: "Correction to my earlier date: the launch is Monday, 18 May, after final review.", isFinal: true)
        entries[54] = TranscriptEntry(id: "late-question", timestamp: start.addingTimeInterval(54 * 60), text: "What day did we settle on for the release after review?", isFinal: true)
        XCTAssertFalse(entries.suffix(24).contains { $0.id == "mid-correction" }, "The correction must fall outside the prompt's recent transcript excerpt.")

        let sessionID = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-live-call-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalSessionStore(directoryURL: directory)
        try await store.save(SavedSession(id: sessionID, revision: 19, transcript: entries.map(SavedTranscriptEntry.init), transcriptRevision: 19))
        let reopenedSession = try await LocalSessionStore(directoryURL: directory).load(id: sessionID).session
        XCTAssertEqual(reopenedSession.transcript.map(\.id), entries.map(\.id))
        let snapshot = CallContextSnapshot(sessionID: reopenedSession.id, revision: reopenedSession.transcriptRevision ?? reopenedSession.revision,
                                           entries: reopenedSession.transcript.map(\.transcriptEntry), workspace: nil)
        let selection = TranscriptSelection(text: entries[54].text, entryIDs: [entries[54].id])
        let agent = OpenAIConversationAgent(apiKeyProvider: { key })
        let question = "Which weekday did we ultimately choose, and did anyone establish that the system cannot fail under any conditions, or was that only a spoken assertion?"
        let investigationID = UUID()
        let finding = try await agent.investigate(selection: selection, question: question, snapshot: snapshot, context: nil, model: model, id: investigationID)

        XCTAssertTrue(finding.summary.localizedCaseInsensitiveContains("Monday"), finding.summary)
        let normalized = finding.summary.lowercased()
        XCTAssertTrue(Self.attributesSpokenClaim(normalized), finding.summary)
        XCTAssertTrue(Self.disclaimsVerification(normalized), finding.summary)
        XCTAssertTrue(finding.evidence.contains {
            $0.transcriptSessionID == sessionID.uuidString &&
            $0.transcriptEntryID == "mid-correction" &&
            $0.excerpt.contains("Monday, 18 May")
        }, "Expected a validated citation to the retrieved midstream correction; got \(finding.evidence)")

        var updated = reopenedSession
        updated.revision += 1
        updated.investigations.append(SavedInvestigation(id: investigationID, selectionText: selection.text, entryIDs: selection.entryIDs,
                                                         question: question, status: "completed", finding: SavedFinding(finding)))
        try await store.save(updated)
        let persisted = try await LocalSessionStore(directoryURL: directory).load(id: sessionID).session
        let persistedEvidence = try XCTUnwrap(persisted.investigations.first(where: { $0.id == investigationID })?.finding?.evidence)
        XCTAssertTrue(persistedEvidence.contains {
            $0.transcriptSessionID == sessionID.uuidString && $0.transcriptEntryID == "mid-correction" && $0.excerpt.contains("Monday, 18 May")
        }, "Transcript citation identity and excerpt must survive saved session reopen")
    }
    // Captured synthetic response from the single authorized live investigation.
    // Test the gate against valid paraphrases without paying for a second run.
    func testClaimGateAcceptsObservedLiveParaphrase() {
        let observed = "The ultimately stated release day was Monday, 18 May, after final review; the earlier Friday plan was explicitly corrected. The claim that the controller would never fail under any load appears only as a spoken assertion in the inspected call. No supporting system evidence was inspected, so the call does not establish that it cannot fail under all conditions."
        XCTAssertTrue(Self.attributesSpokenClaim(observed.lowercased()))
        XCTAssertTrue(Self.disclaimsVerification(observed.lowercased()))
        XCTAssertFalse(Self.disclaimsVerification("The controller is guaranteed never to fail under any load.".lowercased()))
    }

    private static func attributesSpokenClaim(_ text: String) -> Bool {
        ["said", "claimed", "asserted", "spoken assertion", "speaker claims"].contains(where: text.contains)
    }

    private static func disclaimsVerification(_ text: String) -> Bool {
        ["not established", "not verified", "unverified", "cannot establish", "cannot verify", "not proven", "not proof", "does not establish"].contains(where: text.contains)
    }

}
