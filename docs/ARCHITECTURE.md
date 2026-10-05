# Architecture

```text
Explicit Start + selected audio source
                  |
ScreenCaptureKit → 24 kHz mono PCM → Realtime transcription
                                         |
                          stable transcript items in memory
                                /                   \
             coalesced Context update         selected passage + question
                        |                              |
            previous understanding            dedicated investigation
              + recent transcript             + full-call snapshot tools
                        |                              |
             direct API agent                 direct API agent
                        |                              |
             evolving Context pane            retained passage result
```

## Audio and transcription

ScreenCaptureKit provides microphone, system, or combined audio. The existing timestamp-aligned mixer, bounded serialized audio queue, local voice-activity detection, and explicit speech commits remain the capture boundary. An independent bounded recording writer retains selected sources before mixing, enabling versioned post-call transcription. See [temporary audio decision](adr/0001-temporary-call-audio.md).

Capture conversion runs on its own sample queue. `AudioDeliveryWorker` transfers PCM to the transcription actor through a single detached consumer, independently of the MainActor UI. Its synchronized mailbox holds at most two seconds of PCM including an in-flight send, coalesces wakeups, and reports overflow once. Stop closes the mailbox and joins the worker before disconnecting, preventing an old send from entering a new connection. UI changes stay on MainActor; agent requests and local file tools already execute in their own actors. These are independent execution domains managed by Swift concurrency, not permanently assigned OS threads.

The WebSocket selects transcription intent (`?intent=transcription`). The chosen transcription model is configured under `audio.input.transcription.model`, not as a realtime session model. Capture starts after `session.updated`. Partial and completed events carry item identities, allowing one transcript entry to be revised without replacing the entire conversation.

Capture generations reject events from stopped sessions. Conversation identity separately protects agent results, so resuming recording can preserve the conversation while New conversation invalidates previous work.

`RecoveringTranscriptionClient` owns fresh connection instances across up to three transport-recovery attempts per listening session. It drops audio while disconnected, never replays uncertain sends, namespaces provider item IDs per connection, and rejects stale callbacks. API rejections remain terminal. Recovery notices and interrupted partials persist in the transcript; the notice timestamps describe detection and recovery rather than exact lost-audio boundaries. Stop invalidates recovery before awaiting transport teardown.

## Context and investigations

AppModel owns the in-memory transcript, last successful Context, and passage investigations. Automatic Context updates debounce completed speech, limit update frequency, and coalesce changes during an in-flight request. Each run captures an immutable CallContextSnapshot with session ID, revision, full transcript, and optional authorized workspace. The prompt begins with a bounded recent transcript plus the previous understanding; bounded read-window and search tools expose older entries without reading other session files. Existing Context stays visible until a successful replacement arrives.

OpenAIConversationAgent requests structured findings containing a title, summary, confidence, and transcript or file evidence. Context prompts preserve useful prior understanding, distinguish claims from evidence, and surface decisions and unanswered questions. Investigations receive the selected passage, the full-call snapshot, an optional question, and current understanding in an independent run.

The production agent uses OpenAI Responses with structured output and a bounded tool loop. It replays response output and function results within a run, sends explicit bounded conversation state between runs, and requests `store: false`. Call-only runs expose only read_call_transcript and search_call_transcript. Transcript citations are accepted only for tool-returned exact text in finalized, uninterrupted, non-system entries with matching session and unique entry IDs. Optional local file tools list, search, and read explicitly authorized workspace files, enforce path and exclusion rules per access, and track returned snippets for evidence validation. Cancellation and conversation generations reject stale results.

The model catalog is fetched from `/v1/models` using the configured OpenAI API credential. Context and investigation model IDs are explicit, remembered choices. Unknown/new IDs are not filtered by model-family allowlists. Catalog availability does not imply Responses/tool/schema compatibility; failures remain visible without model substitution. The existing Codex implementation is retained as legacy code and for regression tests, but the production app does not launch it.

## Workspace and credentials

The workspace loader supplies folder validation and bounded local indexing. Local keyword matching is not the Context trigger or displayed recall product. Agent filesystem access is distinct from the index: index exclusions are not a sandbox policy.

New conversations default to Call only. Recent workspace paths and per-workspace consent persist in preferences but are not restored into new calls. Call-agent enablement persists separately and grants no file access. A missing saved workspace remains a relinking state, distinct from intentionally folderless calls. The OpenAI key shared by transcription and agents lives in macOS Keychain; an existing launch-environment key takes precedence for development. Transcript, Context, and investigations are persisted as versioned local session snapshots; temporary audio is stored separately with bounded retention. Credentials and runtime tasks are excluded from snapshots.

Session storage is separate from runtime models. A serialized store writes per-session snapshots atomically and keeps a validated previous copy for recovery. Session identities and revisions prevent stale writes, and deletion invalidates delayed saves. Unsupported future schemas must not be overwritten. See [Local session history](PERSISTENCE.md) for the decision, scope, and adversarial verification checklist.

## Lifecycle

Stop closes capture/transcription and cancels active work while retaining displayed conversation data. New conversation saves the current session before clearing the view and invalidating old results. History restores saved content paused without provider calls; resuming or retrying work is explicit. Save failures remain visible and must not silently discard unsaved content. Workspace changes require an empty conversation. Failures remain visible without erasing the last useful result.

The app is a locally signed, non-App-Sandboxed direct-download build. Local tool path restrictions are application-enforced, not an OS sandbox. Native file evidence links are constrained to the selected workspace.
