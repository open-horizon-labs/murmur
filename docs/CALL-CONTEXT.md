# Call-scoped Context: option C

## Aim and scope

An ordinary call should receive evolving Context and focused passage investigations without choosing a project folder. Call-only runs use the existing direct API agent with read-only tools over an immutable snapshot of that call. No temporary filesystem workspace, writable agent, attachment ingestion, web research, or cross-call search is introduced.

New conversations start Call only. The remembered call-agent switch enables transcript requests; folder consent is separate. Selecting and authorizing a folder before a call adds existing file tools. Attaching a folder to a call already containing speech is deferred; start a new conversation to change its source boundary. Saved calls reopen paused. A missing linked folder remains a visible relinking requirement.

## Implementation

`CallContextSnapshot` carries session UUID, transcript revision, all transcript entries, and an optional authorized folder. Each request captures this value before launching. The prompt includes bounded recent speech and prior Context; `read_call_transcript` navigates older windows and `search_call_transcript` locates matching passages. The model interprets the retrieved conversation, including paraphrases and corrections. Existing call-count, timeout, cancellation, and coalescing limits still apply.

Transcript evidence requires a matching session UUID, unique stable entry ID, and exact excerpt actually returned by a tool. Partial speech, interrupted speech, and system notices cannot support settled citations. Evidence is preserved in History and exports. Clicking a transcript source selects the matching passage; appended speech preserves the selection. Spoken assertions remain claims made during the call, not independent verification.

## Execution checks

| Risk | Wrong shortcut the check rejects | Evidence |
| --- | --- | --- |
| Old folder inherited by new calls | Reuse last folder as an implicit scratch workspace | RecentWorkspaceStoreTests default-launch test; call-only tool definitions omit every filesystem tool |
| Missing linked folder silently changes meaning | Treat every nil workspace URL as call-only | AppModelSessionTests missing-folder test blocks listening and agents until relink |
| Context sees only recent speech | Increase the recent prompt window or rely only on literal query terms | Opt-in synthetic live fixture: early Friday plan, Monday correction outside last 24 entries, late paraphrased release question |
| Evidence fabricated or never seen | Validate against whole snapshot regardless of tool return | CallTranscriptToolsTests: unreturned byte-budget entries, clipped tails, wrong session, duplicate IDs, partial/interrupted/system entries |
| Live UI changes agent scope | Tool reads active AppModel or global history instead of snapshot | ConversationSchedulingTests switches sessions while first run is held; stale publication rejected; snapshot content remains isolated |
| Citation jumps to wrong repeated text | Search whole rendered transcript by words alone | Native NSTextView test selects second matching entry and retains it after append |
| Saved results lose provenance | Store only a summary string or ephemeral tool state | Live synthetic fixture persists/reloads session and resulting evidence; app session round-trip test |
| Spoken claim presented as proven | Treat transcript as external factual evidence | Prompt distinction plus synthetic guarantee-claim check |
| Audio reliability regresses | Route agent tools through audio/UI work | Existing audio delivery, capture, recovery and session lifecycle suites; no audio pipeline edits |

Actual-call usefulness, transcription accuracy in a particular meeting, and whether the Context is timely enough still require a human dogfood trial. No automated claim of production readiness is made.

## Review and rollout record

Current state: implementation and review complete; 126 local tests passed, seven opt-in tests skipped, final compile-only build succeeded. The synthetic live response satisfied the behavioral checks; two overly narrow wording assertions were corrected using its captured response without another paid request. Signing recovered after the user’s unlock without changing identities. Version 0.5.0 build 11 is installed and its signature verified; native UI confirms Call only, optional folder access, explicit call-agent enablement, and retained model choices. An actual-call trial remains pending. Verification details are recorded in IMPLEMENTATION.md. The original 0.4.3 source is preserved under build/call-only-baseline/source.tar.gz. This directory is not a Git checkout; integration is in place rather than a merge or PR.
