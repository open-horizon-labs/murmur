import Foundation
import XCTest
@testable import MurmurApp

final class OpenAIResponsesTests: XCTestCase {
    func testCustomContextInstructionsReachLiveAndFinalRequests() async throws {
        for isFinal in [false, true] {
            let finding = #"{"title":"Notes","summary":"No speech yet","confidence":0.5,"skillsUsed":[],"evidence":[]}"#
            let content: JSONValue = .object(["type": .string("output_text"), "text": .string(finding)])
            let message: JSONValue = .object(["type": .string("message"), "content": .array([content])])
            let done: JSONValue = .object(["status": .string("completed"), "output": .array([message])])
            let transport = FakeResponsesTransport([(try encoded(done), response(200))])
            let agent = OpenAIConversationAgent(apiKeyProvider: { "test-key" }, client: OpenAIResponsesClient(transport: transport))
            let snapshot = CallContextSnapshot(sessionID: UUID(), revision: 1, entries: [], workspace: nil,
                                               isFinalReview: isFinal, contextGuidance: "CUSTOM_GUIDANCE: focus on next steps.")
            _ = try await agent.updateContext(snapshot: snapshot, previous: nil, model: "test")
            let requests = await transport.requests
            let payload = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(requests.first?.httpBody))
            let body = String(decoding: try XCTUnwrap(requests.first?.httpBody), as: UTF8.self)
            XCTAssertTrue(body.contains("CUSTOM_GUIDANCE: focus on next steps."))
            let instructions = try XCTUnwrap(payload["instructions"]?.stringValue)
            XCTAssertTrue(instructions.contains("untrusted data"))
            if isFinal { XCTAssertTrue(instructions.contains("read every finalized transcript entry")) }
        }
    }

    func testDiscoveryUsesRawUnknownModelIDsAndEmptySkills() async throws {
        let transport = FakeResponsesTransport([(data("{\"data\":[{\"id\":\"future-model-x\",\"created\":1,\"owned_by\":\"openai\"},{\"id\":\"legacy-model\",\"created\":2,\"owned_by\":\"openai\"}]}"), response(200))])
        let client = OpenAIResponsesClient(transport: transport)
        let models = try await client.listModels(apiKey: "test-key")
        XCTAssertEqual(models.map(\.model), ["future-model-x", "legacy-model"])
        XCTAssertTrue(models.allSatisfy { $0.displayName == $0.model && !$0.isDefault })
    }

    func testProviderModelCompatibilityErrorIsFriendlyAndDoesNotEchoBody() async throws {
        let transport = FakeResponsesTransport([(data("{\"error\":{\"message\":\"Unsupported model test-key\"}}"), response(400))])
        let client = OpenAIResponsesClient(transport: transport)
        do {
            _ = try await client.createResponse(apiKey: "test-key", payload: .object(["model": .string("future-model")]))
            XCTFail("Expected provider error")
        } catch let error as ResponsesClientError {
            guard case .provider(let status, let message) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(status, 400)
            XCTAssertFalse(message.contains("test-key"))
        }
    }

    func testToolRoundReplaysAllResponseItemsAndCollectsOnlyInspectedCitations() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let first: JSONValue = .object(["status": .string("completed"), "output": .array([
            .object(["type": .string("reasoning"), "id": .string("rs_1"), "summary": .array([])]),
            .object(["type": .string("function_call"), "id": .string("fc_1"), "call_id": .string("call_1"), "name": .string("search_workspace"), "arguments": .string("{\"query\":\"maximumAttempts\",\"directory\":null}")])
        ])])
        let findingJSON = "{\"title\":\"Retry policy\",\"summary\":\"Four attempts are allowed.\",\"confidence\":0.92,\"skillsUsed\":[],\"evidence\":[{\"path\":\"RetryPolicy.swift\",\"lineStart\":2,\"lineEnd\":2,\"excerpt\":\"static let maximumAttempts = 4\"}]}"
        let second: JSONValue = .object(["status": .string("completed"), "output": .array([
            .object(["type": .string("reasoning"), "id": .string("rs_2"), "summary": .array([])]),
            .object(["type": .string("function_call"), "id": .string("fc_2"), "call_id": .string("call_2"), "name": .string("list_workspace_files"), "arguments": .string("{\"directory\":null}")])
        ])])
        let third: JSONValue = .object(["status": .string("completed"), "output": .array([
            .object(["type": .string("reasoning"), "id": .string("rs_3"), "summary": .array([])]),
            .object(["type": .string("message"), "content": .array([.object(["type": .string("output_text"), "text": .string(findingJSON)])])])
        ])])
        let transport = FakeResponsesTransport([(try encoded(first), response(200)), (try encoded(second), response(200)), (try encoded(third), response(200))])
        let client = OpenAIResponsesClient(transport: transport)
        let agent = OpenAIConversationAgent(apiKeyProvider: { "test-key" }, client: client)
        let finding = try await agent.updateContext(transcript: [], previous: nil, workspace: workspace, model: "unreleased-model")
        XCTAssertEqual(finding.evidence.count, 1)
        XCTAssertEqual(finding.evidence[0].path, "RetryPolicy.swift")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
        let secondBody = try XCTUnwrap(requests[1].httpBody)
        let replay = try JSONDecoder().decode(JSONValue.self, from: secondBody)
        guard case .array(let inputs)? = replay["input"] else { return XCTFail("Second call did not replay input") }
        XCTAssertTrue(inputs.contains { $0["type"]?.stringValue == "reasoning" && $0["id"]?.stringValue == "rs_1" })
        XCTAssertTrue(inputs.contains { $0["type"]?.stringValue == "function_call" && $0["call_id"]?.stringValue == "call_1" })
        XCTAssertTrue(inputs.contains { $0["type"]?.stringValue == "function_call_output" && $0["call_id"]?.stringValue == "call_1" })
        XCTAssertTrue(inputs.contains { item in
            guard item["type"]?.stringValue == "message", case .array(let contents)? = item["content"] else { return false }
            return contents.first?["text"]?.stringValue?.contains("Update the evolving Context") == true
        })
        let thirdBody = try XCTUnwrap(requests[2].httpBody)
        let thirdPayload = try JSONDecoder().decode(JSONValue.self, from: thirdBody)
        guard case .array(let replayAgain)? = thirdPayload["input"] else { return XCTFail("Third call did not replay input") }
        XCTAssertTrue(replayAgain.contains { $0["type"]?.stringValue == "function_call" && $0["call_id"]?.stringValue == "call_2" })
        XCTAssertTrue(replayAgain.contains { $0["type"]?.stringValue == "function_call_output" && $0["call_id"]?.stringValue == "call_2" })
        XCTAssertTrue(replayAgain.contains { $0["type"]?.stringValue == "reasoning" && $0["id"]?.stringValue == "rs_1" })
        let firstBody = try XCTUnwrap(requests.first?.httpBody)
        let firstPayload = try JSONDecoder().decode(JSONValue.self, from: firstBody)
        XCTAssertEqual(firstPayload["store"]?.boolValue, false)
        XCTAssertNil(firstPayload["reasoning"])
    }

    func testCallOnlyNeverExposesOrExecutesWorkspaceTools() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "OTHER_FOLDER_CANARY".write(to: workspace.appendingPathComponent("canary.txt"), atomically: true, encoding: .utf8)
        let call: JSONValue = .object(["status": .string("completed"), "output": .array([
            .object(["type": .string("function_call"), "call_id": .string("rogue"), "name": .string("read_workspace_file"), "arguments": .string("{\"path\":\"\(workspace.path)/canary.txt\",\"line_start\":1,\"line_end\":10}")])
        ])])
        let done: JSONValue = .object(["status": .string("completed"), "output": .array([
            .object(["type": .string("message"), "content": .array([.object(["type": .string("output_text"), "text": .string(#"{"title":"Call","summary":"Spoken claim only","confidence":0.5,"skillsUsed":[],"evidence":[]}"#)])])])
        ])])
        let transport = FakeResponsesTransport([(try encoded(call), response(200)), (try encoded(done), response(200))])
        let agent = OpenAIConversationAgent(apiKeyProvider: { "test-key" }, client: OpenAIResponsesClient(transport: transport))
        _ = try await agent.updateContext(snapshot: CallContextSnapshot(sessionID: UUID(), revision: 1, entries: [], workspace: nil), previous: nil, model: "test")
        let requests = await transport.requests
        let payload = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(requests[0].httpBody))
        guard case .array(let definitions)? = payload["tools"] else { return XCTFail("Missing tools") }
        XCTAssertEqual(Set(definitions.compactMap { $0["name"]?.stringValue }), Set(["read_call_transcript", "search_call_transcript"]))
        let replay = String(decoding: try XCTUnwrap(requests[1].httpBody), as: UTF8.self)
        XCTAssertFalse(replay.contains("OTHER_FOLDER_CANARY"))
        XCTAssertTrue(replay.contains("could not complete"))
    }

    func testFinalReviewRejectsUninspectedTranscriptAndAcceptsCompleteRead() async throws {
        let sessionID = UUID()
        let entry = TranscriptEntry(id: "postcall:window-0:0", timestamp: Date(), text: "The release is Monday, not Friday.", isFinal: true)
        let snapshot = CallContextSnapshot(sessionID: sessionID, revision: 7, entries: [entry], workspace: nil, isFinalReview: true)
        let finding = #"{"title":"Final call review","summary":"Release is Monday, not Friday.","confidence":0.9,"skillsUsed":[],"evidence":[]}"#
        let noRead = JSONValue.object(["status": .string("completed"), "output": .array([
            .object(["type": .string("message"), "content": .array([.object(["type": .string("output_text"), "text": .string(finding)])])])
        ])])
        let rejectedAgent = OpenAIConversationAgent(apiKeyProvider: { "test-key" }, client: OpenAIResponsesClient(transport: FakeResponsesTransport([(try encoded(noRead), response(200))])))
        do {
            _ = try await rejectedAgent.updateContext(snapshot: snapshot, previous: nil, model: "test")
            XCTFail("Final review must not accept an answer before full transcript inspection.")
        } catch let error as OpenAIConversationAgentError {
            guard case .incompleteFinalTranscript(let remaining) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(remaining, 1)
        }

        let read = JSONValue.object(["status": .string("completed"), "output": .array([
            .object(["type": .string("function_call"), "call_id": .string("read-1"), "name": .string("read_call_transcript"), "arguments": .string("{\"offset\":0,\"limit\":24}")])
        ])])
        let done = JSONValue.object(["status": .string("completed"), "output": .array([
            .object(["type": .string("message"), "content": .array([.object(["type": .string("output_text"), "text": .string(finding)])])])
        ])])
        let transport = FakeResponsesTransport([(try encoded(read), response(200)), (try encoded(done), response(200))])
        let acceptedAgent = OpenAIConversationAgent(apiKeyProvider: { "test-key" }, client: OpenAIResponsesClient(transport: transport))
        _ = try await acceptedAgent.updateContext(snapshot: snapshot, previous: nil, model: "test")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(String(decoding: try XCTUnwrap(requests[1].httpBody), as: UTF8.self).contains("The release is Monday, not Friday."))
    }

    func testFinalContextPresentationReplaysAnonymizedSavedOutputWithoutProviderIDs() throws {
        // An anonymized replay of the saved synthetic live Context response.
        let sessionID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let entryID = "postcall:11111111-2222-4333-8444-555555555555:aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee:99999999-8888-4777-8666-555555555555:window-0:0"
        let snapshot = CallContextSnapshot(
            sessionID: sessionID, revision: 4,
            entries: [TranscriptEntry(id: entryID, timestamp: Date(timeIntervalSince1970: 0), text: "The release is Monday, not Friday. We do not need a weekly call unless there is something to discuss.", isFinal: true)],
            workspace: nil, isFinalReview: true
        )
        let savedOutput = #"{"title":"Infrastructure plan and release timing","summary":"**Summary** The estimate is eight to ten GPU instances, pending load testing. [Session 11111111-2222-4333-8444-555555555555, entry postcall:11111111-2222-4333-8444-555555555555:aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee:99999999-8888-4777-8666-555555555555:window-0:0: “We reviewed the infrastructure plan. Do not grant production access. The initial estimate is eight to ten GPU instances, but capacity is not decided until load testing.”] [Same entry: “We initially suggested a weekly call on Tuesday. Correction: we do not need a weekly call unless there is something to discuss.”] [Same entry: “The release is Monday, not Friday.”]","evidence":[{"transcriptSessionID":"11111111-2222-4333-8444-555555555555","transcriptEntryID":"postcall:11111111-2222-4333-8444-555555555555:aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee:99999999-8888-4777-8666-555555555555:window-0:0","excerpt":"The release is Monday, not Friday."}]}"#
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(savedOutput.utf8)) as? [String: Any])
        let title = try XCTUnwrap(response["title"] as? String)
        let summary = try XCTUnwrap(response["summary"] as? String)

        let presentedTitle = FinalContextPresentation.sanitized(title, snapshot: snapshot)
        let presentedSummary = FinalContextPresentation.sanitized(summary, snapshot: snapshot)
        XCTAssertFalse(presentedTitle.localizedCaseInsensitiveContains(sessionID.uuidString))
        XCTAssertFalse(presentedSummary.localizedCaseInsensitiveContains(sessionID.uuidString))
        XCTAssertFalse(presentedTitle.contains(entryID))
        XCTAssertFalse(presentedSummary.contains(entryID))
        XCTAssertTrue(presentedSummary.contains("The release is Monday, not Friday."))
        XCTAssertTrue(presentedSummary.contains("Correction: we do not need a weekly call unless there is something to discuss."))
        XCTAssertTrue(presentedSummary.contains("We reviewed the infrastructure plan. Do not grant production access."))
        XCTAssertEqual(FinalContextPresentation.sanitized("entry: \(entryID)", snapshot: snapshot), "entry: ")
        XCTAssertFalse([sessionID.uuidString, "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", "99999999-8888-4777-8666-555555555555"].contains(where: presentedSummary.localizedCaseInsensitiveContains))
        let evidence = try XCTUnwrap(response["evidence"] as? [[String: String]])
        XCTAssertEqual(evidence.first?["transcriptEntryID"], entryID)
    }

    func testResetCancelsAnOutstandingRequestAndPreventsLateFinding() async throws {
        let transport = FakeResponsesTransport([])
        let client = OpenAIResponsesClient(transport: transport)
        let agent = OpenAIConversationAgent(apiKeyProvider: { "test-key" }, client: client)
        let pending = Task { try await agent.updateContext(transcript: [], previous: nil, workspace: FileManager.default.temporaryDirectory, model: "slow-model") }
        await transport.waitForRequestCount(1)
        await agent.resetConversation()
        do { _ = try await pending.value; XCTFail("Expected reset cancellation") }
        catch is CancellationError { }
    }

    func testDeadlineAndRefusalAreReportedWithoutReturningFindings() async throws {
        let slowTransport = FakeResponsesTransport([])
        let slowAgent = OpenAIConversationAgent(apiKeyProvider: { "test-key" }, client: OpenAIResponsesClient(transport: slowTransport), contextTimeout: .milliseconds(20))
        do {
            _ = try await slowAgent.updateContext(transcript: [], previous: nil, workspace: FileManager.default.temporaryDirectory, model: "slow-model")
            XCTFail("Expected deadline")
        } catch let error as OpenAIConversationAgentError {
            guard case .timedOut(let model) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(model, "slow-model")
        }

        let refused: JSONValue = .object(["status": .string("completed"), "output": .array([
            .object(["type": .string("message"), "content": .array([.object(["type": .string("refusal"), "refusal": .string("not available")])])])
        ])])
        let refusalAgent = OpenAIConversationAgent(apiKeyProvider: { "test-key" }, client: OpenAIResponsesClient(transport: FakeResponsesTransport([(try encoded(refused), response(200))])))
        do {
            _ = try await refusalAgent.updateContext(transcript: [], previous: nil, workspace: FileManager.default.temporaryDirectory, model: "refusing-model")
            XCTFail("Expected refusal")
        } catch let error as OpenAIConversationAgentError {
            guard case .requestFailed(let model, let message) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(model, "refusing-model")
            XCTAssertTrue(message.lowercased().contains("declined"))
        }
    }

    func testContextCanFinishBeyondOldLookupLimit() async throws {
        let transport = FakeResponsesTransport(try lookupReplies(rounds: 8, callsPerRound: 2) + [summaryReply()])
        let agent = OpenAIConversationAgent(apiKeyProvider: { "test-key" }, client: OpenAIResponsesClient(transport: transport))
        let finding = try await agent.updateContext(snapshot: emptySnapshot(), previous: nil, model: "test")
        XCTAssertEqual(finding.summary, "Finished from inspected evidence.")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 9)
        XCTAssertEqual(try payload(requests.last!)["tool_choice"]?.stringValue, "auto")
    }

    func testRoundBudgetReservesOneSummaryOnlyResponse() async throws {
        let transport = FakeResponsesTransport(try lookupReplies(rounds: 30, callsPerRound: 1) + [summaryReply()])
        let agent = OpenAIConversationAgent(apiKeyProvider: { "test-key" }, client: OpenAIResponsesClient(transport: transport))
        _ = try await agent.updateContext(snapshot: emptySnapshot(), previous: nil, model: "test")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 31)
        XCTAssertEqual(try payload(requests.last!)["tool_choice"]?.stringValue, "none")
        XCTAssertTrue(String(decoding: requests.last!.httpBody!, as: UTF8.self).contains("call_29_0"))
    }

    func testCallBudgetReturnsHonestOutputsForOverflowBeforeSummary() async throws {
        let transport = FakeResponsesTransport(try lookupReplies(rounds: 1, callsPerRound: 122) + [summaryReply()])
        let agent = OpenAIConversationAgent(apiKeyProvider: { "test-key" }, client: OpenAIResponsesClient(transport: transport))
        _ = try await agent.updateContext(snapshot: emptySnapshot(), previous: nil, model: "test")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        let final = try payload(requests.last!)
        XCTAssertEqual(final["tool_choice"]?.stringValue, "none")
        guard case .array(let input)? = final["input"] else { return XCTFail("Missing tool history") }
        let outputs = input.filter { $0["type"]?.stringValue == "function_call_output" }
        XCTAssertEqual(outputs.count, 122)
        XCTAssertEqual(outputs.filter { $0["output"]?.stringValue?.hasPrefix("Not executed:") == true }.count, 2)
    }

    func testSummaryTurnCannotContinueToolLoop() async throws {
        let transport = FakeResponsesTransport(try lookupReplies(rounds: 31, callsPerRound: 1))
        let agent = OpenAIConversationAgent(apiKeyProvider: { "test-key" }, client: OpenAIResponsesClient(transport: transport))
        do {
            _ = try await agent.updateContext(snapshot: emptySnapshot(), previous: nil, model: "looping-model")
            XCTFail("Expected finite tool budget")
        } catch let error as OpenAIConversationAgentError {
            guard case .toolBudgetExceeded = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 31)
    }

    func testCustomContextRoundLimitAndInvestigationIsolation() async throws {
        let snapshot = CallContextSnapshot(sessionID: UUID(), revision: 1, entries: [], workspace: nil,
                                           contextLimits: ContextRunLimits(lookupRounds: 2, toolCalls: 10, timeoutSeconds: 90))
        let transport = FakeResponsesTransport(try lookupReplies(rounds: 2, callsPerRound: 1) + [summaryReply()])
        let agent = OpenAIConversationAgent(apiKeyProvider: { "test-key" }, client: OpenAIResponsesClient(transport: transport))
        _ = try await agent.updateContext(snapshot: snapshot, previous: nil, model: "test")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(try payload(requests.last!)["tool_choice"]?.stringValue, "none")

        let investigationTransport = FakeResponsesTransport(try lookupReplies(rounds: 3, callsPerRound: 1) + [summaryReply()])
        let investigator = OpenAIConversationAgent(apiKeyProvider: { "test-key" }, client: OpenAIResponsesClient(transport: investigationTransport))
        _ = try await investigator.investigate(selection: TranscriptSelection(text: "Explain this", entryIDs: []), question: "Explain", snapshot: snapshot, context: nil, model: "test", id: UUID())
        let investigationRequests = await investigationTransport.requests
        XCTAssertEqual(investigationRequests.count, 4)
        XCTAssertEqual(try payload(investigationRequests.last!)["tool_choice"]?.stringValue, "auto")
    }

    func testCustomContextToolLimitPairsOverflowOutputs() async throws {
        let snapshot = CallContextSnapshot(sessionID: UUID(), revision: 1, entries: [], workspace: nil,
                                           contextLimits: ContextRunLimits(lookupRounds: 8, toolCalls: 3, timeoutSeconds: 90))
        let transport = FakeResponsesTransport(try lookupReplies(rounds: 1, callsPerRound: 5) + [summaryReply()])
        let agent = OpenAIConversationAgent(apiKeyProvider: { "test-key" }, client: OpenAIResponsesClient(transport: transport))
        _ = try await agent.updateContext(snapshot: snapshot, previous: nil, model: "test")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        let final = try payload(requests.last!)
        XCTAssertEqual(final["tool_choice"]?.stringValue, "none")
        guard case .array(let input)? = final["input"] else { return XCTFail("Missing tool history") }
        let outputs = input.filter { $0["type"]?.stringValue == "function_call_output" }
        XCTAssertEqual(outputs.count, 5)
        XCTAssertEqual(outputs.filter { $0["output"]?.stringValue?.hasPrefix("Not executed:") == true }.count, 2)
    }

    func testEffortIsIncludedAcrossToolAndSummaryTurnsAndDefaultIsOmitted() async throws {
        for effort in ReasoningEffort.allCases {
            let snapshot = CallContextSnapshot(sessionID: UUID(), revision: 1, entries: [], workspace: nil,
                                               contextLimits: ContextRunLimits(lookupRounds: 1), reasoningEffort: effort)
            let transport = FakeResponsesTransport(try lookupReplies(rounds: 1, callsPerRound: 1) + [summaryReply()])
            let agent = OpenAIConversationAgent(apiKeyProvider: { "test-key" }, client: OpenAIResponsesClient(transport: transport))
            _ = try await agent.updateContext(snapshot: snapshot, previous: nil, model: "test")
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 2)
            XCTAssertEqual(try payload(requests.last!)["tool_choice"]?.stringValue, "none")
            for request in requests {
                let body = try payload(request)
                if effort == .modelDefault { XCTAssertNil(body["reasoning"]) }
                else { XCTAssertEqual(body["reasoning"]?["effort"]?.stringValue, effort.rawValue) }
            }
        }
    }

    func testInvestigationSendsItsOwnEffort() async throws {
        let transport = FakeResponsesTransport(try lookupReplies(rounds: 1, callsPerRound: 1) + [summaryReply()])
        let agent = OpenAIConversationAgent(apiKeyProvider: { "test-key" }, client: OpenAIResponsesClient(transport: transport))
        let snapshot = CallContextSnapshot(sessionID: UUID(), revision: 1, entries: [], workspace: nil, reasoningEffort: .high)
        _ = try await agent.investigate(selection: TranscriptSelection(text: "Explain", entryIDs: []), question: "Explain", snapshot: snapshot, context: nil, model: "test", id: UUID())
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        for request in requests { XCTAssertEqual(try payload(request)["reasoning"]?["effort"]?.stringValue, "high") }
    }

    func testUnsupportedEffortSurfacesProviderErrorWithoutRetry() async throws {
        let transport = FakeResponsesTransport([(data(#"{"error":{"message":"Unsupported reasoning effort: max"}}"#), response(400))])
        let agent = OpenAIConversationAgent(apiKeyProvider: { "test-key" }, client: OpenAIResponsesClient(transport: transport))
        let snapshot = CallContextSnapshot(sessionID: UUID(), revision: 1, entries: [], workspace: nil, reasoningEffort: .max)
        do {
            _ = try await agent.updateContext(snapshot: snapshot, previous: nil, model: "test")
            XCTFail("Expected unsupported effort error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Requested reasoning effort: max"))
            XCTAssertTrue(error.localizedDescription.contains("Model default in Settings"))
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    private func emptySnapshot() -> CallContextSnapshot {
        CallContextSnapshot(sessionID: UUID(), revision: 1, entries: [], workspace: nil)
    }

    private func payload(_ request: URLRequest) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(request.httpBody))
    }

    private func lookupReplies(rounds: Int, callsPerRound: Int) throws -> [(Data, HTTPURLResponse)] {
        try (0..<rounds).map { round in
            let calls = (0..<callsPerRound).map { index in
                JSONValue.object(["type": .string("function_call"), "call_id": .string("call_\(round)_\(index)"),
                                  "name": .string("read_call_transcript"), "arguments": .string("{}")])
            }
            return (try encoded(.object(["status": .string("completed"), "output": .array(calls)])), response(200))
        }
    }

    private func summaryReply() throws -> (Data, HTTPURLResponse) {
        let finding = #"{"title":"Context","summary":"Finished from inspected evidence.","confidence":0.5,"skillsUsed":[],"evidence":[]}"#
        let content: JSONValue = .object(["type": .string("output_text"), "text": .string(finding)])
        let message: JSONValue = .object(["type": .string("message"), "content": .array([content])])
        return (try encoded(.object(["status": .string("completed"), "output": .array([message])])), response(200))
    }

    func testLiveContextAndInvestigationWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["MURMUR_LIVE_API_TEST"] == "1",
              let model = ProcessInfo.processInfo.environment["MURMUR_LIVE_API_MODEL"], !model.isEmpty else {
            throw XCTSkip("Set MURMUR_LIVE_API_TEST=1 and MURMUR_LIVE_API_MODEL to run the live Responses API test.")
        }
        let key = try ProcessInfo.processInfo.environment["OPENAI_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
            ?? OpenAIKeychainStore().load()
        guard let key, !key.isEmpty else { throw XCTSkip("An API key is required in OPENAI_API_KEY or the existing Murmur Keychain item.") }
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "enum RetryPolicy { static let maximumAttempts = 4 }".write(to: workspace.appendingPathComponent("RetryPolicy.swift"), atomically: true, encoding: .utf8)
        let agent = OpenAIConversationAgent(apiKeyProvider: { key })
        let context = try await agent.updateContext(transcript: [TranscriptEntry(id: "u1", timestamp: Date(), text: "How many times will we keep hammering an unavailable service before giving up?", isFinal: true)], previous: nil, workspace: workspace, model: model)
        let finding = try await agent.investigate(selection: TranscriptSelection(text: "How many times will we keep hammering an unavailable service before giving up?", entryIDs: ["u1"]), question: "How many attempts are configured before giving up?", surrounding: [], context: context, workspace: workspace, model: model, id: UUID())
        XCTAssertFalse(context.summary.isEmpty)
        XCTAssertFalse(finding.summary.isEmpty)
        XCTAssertTrue(context.evidence.contains { $0.path == "RetryPolicy.swift" && $0.excerpt.contains("maximumAttempts") })
        XCTAssertTrue(finding.evidence.contains { $0.path == "RetryPolicy.swift" && $0.excerpt.contains("maximumAttempts") })
    }

    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-responses-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try "enum RetryPolicy {\n    static let maximumAttempts = 4\n}".write(to: url.appendingPathComponent("RetryPolicy.swift"), atomically: true, encoding: .utf8)
        return url
    }
    private func data(_ string: String) -> Data { Data(string.utf8) }
    private func encoded(_ value: JSONValue) throws -> Data { try JSONEncoder().encode(value) }
    private func response(_ status: Int) -> HTTPURLResponse { HTTPURLResponse(url: URL(string: "https://api.openai.com")!, statusCode: status, httpVersion: nil, headerFields: nil)! }
}

private actor FakeResponsesTransport: ResponsesHTTPTransport {
    private var queued: [(Data, HTTPURLResponse)]
    private(set) var requests: [URLRequest] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    init(_ queued: [(Data, HTTPURLResponse)]) { self.queued = queued }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let ready = waiters.filter { requests.count >= $0.0 }
        waiters.removeAll { requests.count >= $0.0 }
        ready.forEach { $0.1.resume() }
        if !queued.isEmpty { return queued.removeFirst() }
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
    func waitForRequestCount(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}
