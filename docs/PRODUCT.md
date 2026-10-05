# Murmur product direction

## Aim

During a conversation, retain the conversation’s decisions and open questions, with optional supporting workspace facts without leaving the call to search. Murmur is a native Mac companion with explicit listening controls; it never joins or speaks into a call.

## Conversation workspace

Two persistent, resizable panes share the screen:

- **Transcript:** the full saved conversation, with timestamps. Partial words update their own passage; completed passages remain available. Select a passage to investigate it.
- **Context:** an evolving understanding of the conversation, informed by the full call and an optional explicitly selected workspace. It distinguishes what was said, what files establish, and what remains uncertain. Existing context remains visible while an update runs or fails.

Fast keyword matches are no longer a visible product tier or a gate for Context. With Context agents enabled, finalized speech schedules coalesced Context updates. The agent receives recent speech and the previous understanding, plus bounded navigation and search over an immutable snapshot of the full call. Transcript citations identify inspected passages; a spoken claim is not treated as independently verified truth.

**Investigate** takes highlighted transcript text and an optional question. Its result stays attached to the quoted passage, separate from automatic Context. It can run while listening or after stopping and remains cancellable.

## Controls and retention

- New conversations default to **Call only**, without inheriting the previous folder. Call agents have a separate enable control and cannot access folders. A saved conversation linked to a missing folder still requires relinking.
- Start listening is always explicit. Choose Microphone, Mac audio, or Both.
- Stop ends capture and transcription and cancels active agent work. Transcript, Context, and investigations are automatically saved locally.
- Resume explicitly continues the same conversation. New conversation preserves the previous one in History.
- Start a new conversation before switching workspaces, so prior evidence is not attributed to another folder.
- History reopens conversations paused, including when offline. It supports rename, Markdown/JSON export, and local deletion. Unfinished investigations are interrupted rather than automatically retried. Temporary audio supports post-call transcription and expires after processing or its retention limit.
- Workspace agents require consent for the selected folder. Transcription, Context, and investigations use the configured OpenAI API key. Context and investigation model choices are loaded from the live catalog and remembered without automatic substitution.

## First useful trial

Use a small workspace whose contents you know. Speak several related sentences, including a fact that needs workspace context. Confirm that Context finds relevant evidence even without exact wording, retains earlier decisions as speech continues, and opens the cited file. Highlight a passage and ask a focused follow-up. Stop and verify that capture ends while the conversation remains readable.

The trial succeeds when at least one source-backed finding helps the conversation and later speech does not destroy earlier useful context. Longer calls and combined audio require additional real-device validation.

## Boundaries

One call, with an optional explicitly selected local workspace; read-only agent work; local session history; no meeting bots, diarization, automatic external actions, SaaS connectors, cloud sync, or permanent raw audio archive. Model summaries remain fallible and source links support verification.
