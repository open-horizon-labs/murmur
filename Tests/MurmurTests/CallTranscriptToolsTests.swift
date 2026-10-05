import XCTest
@testable import MurmurApp

final class CallTranscriptToolsTests: XCTestCase {
    func testFullHistoryNavigationAndCitationValidation() async throws {
        let sessionID = UUID()
        var entries = (0..<40).map { index in
            TranscriptEntry(id: "entry-\(index)", timestamp: Date(timeIntervalSince1970: TimeInterval(index)), text: "Routine update \(index)", isFinal: true)
        }
        entries[3].text = "We will launch on Friday."
        entries[25].text = "Correction: the launch is Monday, after the legal review."
        entries[30].wasInterrupted = true
        entries[31].text = "SYSTEM CANARY: hidden draft says Tuesday"
        // Use system identity through the existing ID convention.
        entries[31] = TranscriptEntry(id: "system:canary", timestamp: Date(), text: entries[31].text, isFinal: true)
        entries[32].isFinal = false
        let snapshot = CallContextSnapshot(sessionID: sessionID, revision: 8, entries: entries, workspace: nil)
        let tools = CallTranscriptTools(snapshot: snapshot)

        let recent = try await tools.execute(name: "read_call_transcript", arguments: #"{"offset":32,"limit":8}"#)
        XCTAssertFalse(recent.contains("Correction: the launch is Monday"))
        XCTAssertTrue(recent.contains("next_offset=40"))
        let matches = try await tools.execute(name: "search_call_transcript", arguments: #"{"term":"Correction","limit":4}"#)
        XCTAssertTrue(matches.contains("Correction: the launch is Monday"))
        XCTAssertTrue(matches.contains("entry-25"))
        let excludedStates = try await tools.execute(name: "read_call_transcript", arguments: #"{"offset":30,"limit":3}"#)
        XCTAssertTrue(excludedStates.contains("INTERRUPTED_NOT_SETTLED"))
        XCTAssertTrue(excludedStates.contains("SYSTEM_NOTICE_NOT_SPEECH"))
        XCTAssertTrue(excludedStates.contains("PROVISIONAL_NOT_SETTLED"))

        let exact = AgentEvidence(path: "", lineStart: nil, lineEnd: nil, excerpt: "Correction: the launch is Monday", transcriptSessionID: sessionID.uuidString, transcriptEntryID: "entry-25")
        let fabricatedExcerpt = AgentEvidence(path: "", lineStart: nil, lineEnd: nil, excerpt: "The launch is Tuesday", transcriptSessionID: sessionID.uuidString, transcriptEntryID: "entry-25")
        let wrongSession = AgentEvidence(path: "", lineStart: nil, lineEnd: nil, excerpt: "Correction: the launch is Monday", transcriptSessionID: UUID().uuidString, transcriptEntryID: "entry-25")
        let uninspected = AgentEvidence(path: "", lineStart: nil, lineEnd: nil, excerpt: "Routine update 2", transcriptSessionID: sessionID.uuidString, transcriptEntryID: "entry-2")
        let interrupted = AgentEvidence(path: "", lineStart: nil, lineEnd: nil, excerpt: "Routine update 30", transcriptSessionID: sessionID.uuidString, transcriptEntryID: "entry-30")
        let systemNotice = AgentEvidence(path: "", lineStart: nil, lineEnd: nil, excerpt: "SYSTEM CANARY", transcriptSessionID: sessionID.uuidString, transcriptEntryID: "system:canary")
        let provisional = AgentEvidence(path: "", lineStart: nil, lineEnd: nil, excerpt: "Routine update 32", transcriptSessionID: sessionID.uuidString, transcriptEntryID: "entry-32")
        let approved = await tools.validatedEvidence([exact, fabricatedExcerpt, wrongSession, uninspected, interrupted, systemNotice, provisional])
        XCTAssertEqual(approved, [AgentEvidence(path: "", lineStart: nil, lineEnd: nil, excerpt: exact.excerpt, transcriptSessionID: sessionID.uuidString, transcriptEntryID: "entry-25")])
    }

    func testSnapshotIsCopiedAndLongEntryCitationMustBeVisibleInReturnedWindow() async throws {
        let original = TranscriptEntry(id: "one", timestamp: Date(), text: String(repeating: "A", count: 5_000), isFinal: true)
        let snapshot = CallContextSnapshot(sessionID: UUID(), revision: 1, entries: [original], workspace: nil)
        var changed = original
        changed.text = "mutable caller copy"
        let tools = CallTranscriptTools(snapshot: snapshot)
        let returned = try await tools.execute(name: "read_call_transcript", arguments: #"{"offset":0,"limit":1}"#)
        XCTAssertTrue(returned.contains(String(repeating: "A", count: 4_000)))
        let visible = AgentEvidence(path: "", lineStart: nil, lineEnd: nil, excerpt: String(repeating: "A", count: 100), transcriptSessionID: snapshot.sessionID.uuidString, transcriptEntryID: "one")
        let tailText = String(repeating: "A", count: 5_000) + "HIDDENMARKER" + String(repeating: "Z", count: 3_000)
        let tailSnapshot = CallContextSnapshot(sessionID: snapshot.sessionID, revision: 2, entries: [TranscriptEntry(id: "tail", timestamp: Date(), text: tailText, isFinal: true)], workspace: nil)
        let tailTools = CallTranscriptTools(snapshot: tailSnapshot)
        _ = try await tailTools.execute(name: "read_call_transcript", arguments: #"{"offset":0,"limit":1}"#)
        let hiddenTail = AgentEvidence(path: "", lineStart: nil, lineEnd: nil, excerpt: "HIDDENMARKER", transcriptSessionID: snapshot.sessionID.uuidString, transcriptEntryID: "tail")
        let prefixOnly = await tailTools.validatedEvidence([hiddenTail])
        XCTAssertTrue(prefixOnly.isEmpty)
        let tailSearch = try await tailTools.execute(name: "search_call_transcript", arguments: #"{"term":"HIDDENMARKER","limit":1}"#)
        XCTAssertTrue(tailSearch.contains("HIDDENMARKER"))
        let visibleTail = await tailTools.validatedEvidence([hiddenTail])
        XCTAssertEqual(visibleTail.first?.excerpt, "HIDDENMARKER")
        let approved = await tools.validatedEvidence([visible, hiddenTail])
        XCTAssertEqual(approved, [visible])
    }

    func testByteBudgetDoesNotAuthorizeUnreturnedEntriesAndStillAdvancesOnOversizedText() async throws {
        let id = UUID()
        let entries = [
            TranscriptEntry(id: "huge", timestamp: Date(), text: String(repeating: "😀", count: 5_000), isFinal: true),
            TranscriptEntry(id: "later", timestamp: Date(), text: "Later evidence", isFinal: true)
        ]
        let tools = CallTranscriptTools(snapshot: CallContextSnapshot(sessionID: id, revision: 1, entries: entries, workspace: nil))
        let first = try await tools.execute(name: "read_call_transcript", arguments: #"{"offset":0,"limit":2}"#)
        XCTAssertTrue(first.contains("entry text truncated"))
        XCTAssertTrue(first.contains("next_offset=2"))
        let valid = AgentEvidence(path: "", lineStart: nil, lineEnd: nil, excerpt: "Later evidence", transcriptSessionID: id.uuidString, transcriptEntryID: "later")
        let hidden = await tools.validatedEvidence([valid])
        XCTAssertEqual(hidden, [valid])

        let many = (0..<24).map { TranscriptEntry(id: "wide-\($0)", timestamp: Date(), text: String(repeating: "x", count: 1_400), isFinal: true) }
        let budgetTools = CallTranscriptTools(snapshot: CallContextSnapshot(sessionID: id, revision: 2, entries: many, workspace: nil))
        let window = try await budgetTools.execute(name: "read_call_transcript", arguments: #"{"offset":0,"limit":24}"#)
        XCTAssertTrue(window.contains("has_more=true"))
        XCTAssertFalse(window.contains("id=wide-23"))
        let unreturned = AgentEvidence(path: "", lineStart: nil, lineEnd: nil, excerpt: "x", transcriptSessionID: id.uuidString, transcriptEntryID: "wide-23")
        let rejected = await budgetTools.validatedEvidence([unreturned])
        XCTAssertTrue(rejected.isEmpty)
    }

    func testTranscriptEvidenceCodableIsBackwardCompatible() throws {
        let legacy = #"{"path":"notes.md","lineStart":4,"lineEnd":4,"excerpt":"verified line"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AgentEvidence.self, from: legacy)
        XCTAssertNil(decoded.transcriptSessionID)
        XCTAssertNil(decoded.transcriptEntryID)
        let newEvidence = AgentEvidence(path: "", lineStart: nil, lineEnd: nil, excerpt: "spoken line", transcriptSessionID: UUID().uuidString, transcriptEntryID: "entry-a")
        let roundTrip = try JSONDecoder().decode(AgentEvidence.self, from: JSONEncoder().encode(newEvidence))
        XCTAssertEqual(roundTrip, newEvidence)
    }

    func testDuplicateEntryIDsCannotSupportCitations() async throws {
        let id = UUID()
        let entries = [
            TranscriptEntry(id: "same", timestamp: Date(), text: "one", isFinal: true),
            TranscriptEntry(id: "same", timestamp: Date(), text: "two", isFinal: true)
        ]
        let tools = CallTranscriptTools(snapshot: CallContextSnapshot(sessionID: id, revision: 1, entries: entries, workspace: nil))
        _ = try await tools.execute(name: "read_call_transcript", arguments: #"{"offset":0,"limit":2}"#)
        let citation = AgentEvidence(path: "", lineStart: nil, lineEnd: nil, excerpt: "one", transcriptSessionID: id.uuidString, transcriptEntryID: "same")
        let result = await tools.validatedEvidence([citation])
        XCTAssertTrue(result.isEmpty)
    }

    func testSnapshotWithoutWorkspaceRejectsLegacyAgentDefaults() async throws {
        let fake = LegacyConversationFake()
        let snapshot = CallContextSnapshot(sessionID: UUID(), revision: 1, entries: [], workspace: nil)
        do {
            _ = try await fake.updateContext(snapshot: snapshot, previous: nil, model: "legacy")
            XCTFail("Legacy implementation must not silently analyze an absent workspace")
        } catch is SnapshotAgentError {
            // Expected: default adapter preserves old fake APIs without pretending it supports call snapshots.
        }
    }
}

private struct LegacyConversationFake: ConversationAgentManaging {
    func discover(in workspace: URL) async throws -> ([CodexModel], CodexSkillsInventory) { ([], CodexSkillsInventory(skills: [], errors: [])) }
    func updateContext(transcript: [TranscriptEntry], previous: AgentFinding?, workspace: URL, model: String) async throws -> AgentFinding { fatalError("Not called") }
    func investigate(selection: TranscriptSelection, question: String, surrounding: [TranscriptEntry], context: AgentFinding?, workspace: URL, model: String, id: UUID) async throws -> AgentFinding { fatalError("Not called") }
    func cancel(_ tier: AgentTier) async {}
    func cancelInvestigation(id: UUID) async {}
    func resetConversation() async {}
    func stop() async {}
}
