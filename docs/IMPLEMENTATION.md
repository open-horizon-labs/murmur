# Implementation and verification

## 0.5.0 build 11: Call-scoped Context (installed)

Option C is implemented: new calls default to Call only; explicit call-agent enablement supports automatic Context and passage investigations without a folder. Every run captures the complete immutable transcript and optional authorized workspace. Bounded transcript window/search tools inspect older speech; validated session/entry/excerpt citations open the corresponding passage and survive History. Existing audio/recovery code is unchanged. See [scope and adversarial checks](CALL-CONTEXT.md).

GPT-6 Luna implemented the core tools/API changes; the parent integrated the app/UI and reviewed the core. A second coder could not be started because this session reached its agent limit. The tool exposed GPT-6 Luna but no separate fast setting. This is the user's one-time model experiment, not a new default model choice in Murmur.

Verification: 133 tests discovered, 126 passed, seven opt-in tests skipped, zero failures (`build/call-only-tests.log`). Coverage includes no inherited folder, call-only start/agents/save/reopen, missing-linked-folder blocking, cross-session stale results, absence of filesystem tools, exact inspected citation validation, long-entry tail search, and native text selection across appended speech. Prior workspace, audio delivery, capture, recovery, and History regression tests remain green. Disabling agents during an update now clears the busy state and rejects late results. Luna reviewed the parent’s app/UI integration read-only and reported Superego: No concerns; the parent separately reviewed the core and the overall scope.

One synthetic live investigation used `gpt-6-luna` after saving/reopening a 55-entry call. It found and cited a Monday correction outside the last 24 entries, and preserved that evidence after saving/reopening its result. It described the synthetic absolute reliability guarantee as only a spoken assertion that the call does not establish. The original live test log records two false-negative wording assertions (`build/call-only-live.log`): the answer used “spoken assertion” and “does not establish” rather than the gate's expected synonyms. Those gates were corrected, with the captured response added as an offline regression. No second paid request was made. The correction/citation/persistence assertions passed in the original live run.

The final Xcode compile-only build succeeded (`build/call-only-compile.log`), but signing failed twice with `errSecInternalComponent` accessing the existing Apple Development key (`build/call-only-build.log`). Rollout is pending the user's Keychain unlock/approval; installed 0.4.3 remains untouched and idle at the last UI inspection. Original source and installed app are preserved under `build/call-only-baseline`. Native inspection of the new build and an actual-call trial remain pending; do not treat source completion as an installed release.

Rollout retry: both the Debug Apple Development identity and configured Release Developer ID identity fail with `errSecInternalComponent` (`build/call-only-build.log`, `build/call-only-release.log`). Security logs report the keychain unlocked along with key-data decoding errors; unlocking alone is not a confirmed remedy. An attempt to surface interactive signing through Terminal was blocked by the computer-use tool's app restriction. The user needs to run the existing build script in their Terminal session to expose any authorization prompt or reproduce the key-access failure. No keys, access controls, or installed app files were changed.

Rollout completed later on September 29: the original Apple Development identity successfully signed a copy of the old executable after the user's screen unlock, then signed the full 0.5.0 build 11. A partially generated Xcode project was preserved under build/signing-diagnostic/incomplete-Murmur.xcodeproj and regenerated from project.yml. The idle installed app was quit normally, updated, signature-verified, and opened. Native UI confirms Call only with no inherited folder, Start listening available, optional Add folder, explicit Enable call agents, and retained gpt-6-luna choices. No recording or agent permissions were enabled during installation.

Diagnosis: at 17:53:33 the local auth log records CodexComputerUseAuthorizationPlugin:allow, followed by a graphical unlock and a failed SecKeychainLogin (-25293), then the first CSSMERR_CSP_INVALID_DATA errors. This matches reported Locked Use incidents (https://github.com/openai/codex/issues/35553 and /issues/40226); it is evidence of a matching failure sequence, not proof of plugin causation. No certificate, private key, trust setting, or key access control was changed to recover signing. Earlier restart advice was premature. Actual-call validation remains pending.

## 0.4.3: Bounded transcription recovery

Production transcription now uses a recovery owner around fresh Realtime clients. Typed transport interruptions after startup allow at most three recovery attempts per listening session, with 1/2/4-second backoff. Initial setup failures and provider/configuration/authentication rejections do not automatically retry. Stop invalidates both session and connection ownership; a stale handshake cannot revive capture or replace the new connection. Audio during recovery is discarded rather than replayed.

The toolbar reports reconnecting. A persisted system notice records the detected interruption and recovery/stop, explicitly warning that audio around the interruption may be missing. Unfinalized speech is retained as interrupted, including exports. System notices are labelled separately in agent prompts and cannot be selected as spoken passages. The optional saved interruption field decodes older sessions without migration.

Verification: 119 tests discovered, 113 passed, six opt-in checks skipped, zero failures (`build/socket-hardening-regression.log`). Coverage includes bounded retries, simultaneous failures, stale callbacks/IDs, no replay, cancellation during backoff and handshake, nonretryable rejection, persisted gap ordering, and interrupted partials. Independent review found no remaining material concerns. The implementation pass used no live API calls or microphone capture. After explicit rollout authorization, signed 0.4.3 build 10 succeeded (`build/socket-hardening-build.log`), the old app quit normally, and the update was installed at `~/Applications/Murmur.app`. Build and installed signature checks passed. Native launch, restored workspace, and the existing saved call in History were verified; listening remains off. Previous app is backed up under `build/socket-hardening-baseline/Murmur.app`. Recovery during a real call remains unverified.

## 0.4.2: Audio delivery isolation

The audio handoff no longer drains on MainActor. A detached serial consumer and synchronized, duration-bounded PCM mailbox isolate delivery from UI work. Stop joins any in-flight send before a restart can connect. Existing agent and workspace-tool actors remain separate from UI state.

Verification on 2026-09-29: 112 tests discovered, 106 passed, six opt-in checks skipped, zero failures (`build/audio-isolation-regression.log`). New checks deliberately block MainActor while audio drains, verify ordering and the exact byte budget including in-flight audio, latch overflow once, reject late capture callbacks, and hold an in-flight send through Stop/restart. Independent review found no material concerns.

Initial work was source/tests only while the user was on a call. After the user confirmed the call had ended, signed 0.4.2 build 9 succeeded (`build/audio-isolation-build.log`), the old app quit normally, and the new app was installed at `~/Applications/Murmur.app`. Built and installed signatures passed strict verification. Native launch and the saved call in History were verified; the app was left idle. Previous app and source are preserved under `build/audio-isolation-baseline`. Real-call validation of the new worker remains pending. The old app displayed a separate socket-not-connected error before quit; this rollout does not claim to fix that connection failure.

## 0.4.1: Settings clarity

Settings now separates Listening, Context, and API & privacy. Compact model rows explain automatic Context and on-demand passage investigations; a searchable chooser exposes recent choices and a separate exact-ID disclosure. Catalog status appears once, and unlisted selected models retain a visible notice. Workspace consent, credentials, capture locks, session persistence, and model choices are unchanged.

Verification on 2026-09-29: independent review of the UI changes; signed 0.4.1 build 8 and installed signature verification passed (`build/settings-ux-build.log`). Native inspection confirmed the Context layout and preservation of existing workspace/model choices. Further interactive chooser checks were stopped when concurrent user interaction was detected. No microphone capture or model requests were started during this pass. Prior installed app and source were retained under `build/settings-ux-baseline`.

## 0.4.0: Direct API Context and model discovery

Context and passage investigations now use OpenAI Responses directly with bounded local list/search/read tools. The API model catalog is loaded live; selected IDs are explicit, searchable, manually enterable, and remembered. Refresh never substitutes another model. Catalog lookup is independent of workspace file consent; each agent run still requires consent. Context and passage roles can be selected independently.

GPT-6 Luna coding agents implemented the API client, tool loop, workspace tools, model persistence, Settings UI, and tests. Parent integration and independent review corrected full tool-history replay, citation lifetime and nullable line handling, direct-read ignore enforcement (including symlinks, character classes, case variants, and policy changes), transient model drafts, and regression fixtures that assumed automatic model selection. Local session storage and the existing audio code were preserved.

Verification on 2026-09-29:

- 107 deterministic-suite tests discovered: 101 passed, six opt-in checks skipped, zero failures (`build/api-migration-tests.log`).
- Live `/v1/models` returned 140 IDs including the GPT-6 family, using the configured API credential.
- A separately enabled GPT-6 Luna test passed Context and investigation against a synthetic workspace from an indirect spoken clue; both retained verified source citations. Runtime: 24.6 seconds for both operations (`build/api-migration-live.log`). No microphone or private workspace data was used in this check.
- Signed 0.4.0 build 7 succeeded and was installed at `~/Applications/Murmur.app`; both build and installed app passed strict code-signature verification (`build/api-migration-build.log`). Native Settings loaded the live catalog, filtered both selectors to the three GPT-6 IDs, and kept selections empty while searching. History opened successfully and showed no saved conversations. Capture remained off. Source and previous installed app were backed up under `build/api-migration-baseline`.

This checkout is not a Git repository; reviewed changes were integrated in place. See [the API migration decision](API-MIGRATION.md). Successful synthetic requests do not establish long-call or combined-audio reliability.

## 0.3.0: Local session history

Option B adds versioned local autosave for transcript, latest Context, and passage investigations. History opens sessions paused and supports rename, Markdown/JSON export, and local deletion. New preserves the old session. A save failure prevents silent discard on New/Open/Quit; normal Quit waits for saving. Raw audio and credentials are excluded.

GPT-6 Luna subagents implemented storage/export, lifecycle integration, UI, tests, and quit handling. Parent and independent review corrected future-schema probing, incomplete deletion visibility, same-store backup revision recovery, empty-session creation, capture identity reuse, investigation provenance, and failed-save transitions.

Verification on 2026-09-29: 86 tests discovered, 81 passed, 5 opt-in skipped, no failures (`build/persistence-tests.log`). Signed 0.3.0 build 5 and strict signature verification passed (`build/persistence-build.log`). Installed 0.3.0 build 5, verified its signature, launched it, and confirmed History on 2026-09-29. Native forced-exit/reopen verification remains pending. The subsequent 0.2.0 audio crash investigation was stopped at the user's request; the installed 0.3.0 artifact does not include that unfinished fix. See [persistence verification](PERSISTENCE.md) for adversarial checks and boundaries.

## 0.2.0: Transcript and Context

The approved product direction replaces visible Fast matches with a full transcript, evolving workspace-informed Context, and focused investigations from highlighted passages.

Implementation areas:

- Stable transcript entries keyed by transcription item ID, with timestamps and partial/final state.
- Stop retains in-memory conversation data; Resume continues it; New conversation clears it.
- Debounced, rate-limited, single-flight automatic Context work, with a coalesced follow-up when more speech arrives.
- Bounded recent transcript plus previous understanding in each Context request.
- Independent, cancellable investigations with their original quoted passage and question.
- Native selectable transcript text and a resizable two-pane window.
- Read-only structured findings, visible progress/failure, and workspace-constrained file links.

## Previously verified

The 0.1.2 microphone trial produced live transcription and relevant local-file recall. Both Live and Accurate transcription session handshakes were accepted by OpenAI. The transcription WebSocket uses `intent=transcription`, with the model nested under `audio.input.transcription.model`.

The prior reliability pass added local speech detection and explicit commits, session-readiness acknowledgement, bounded ordered audio delivery, stale-callback rejection, capture error reporting, and timestamp-aligned combined mixing. These remain in place.

## Verification on 2026-09-28

- Final Swift suite: 64 discovered tests, 59 passed, 5 opt-in checks skipped, no failures. Log: `build/context-redesign-tests.log`.
- A separately enabled real Codex test passed one Context update and one passage investigation against a synthetic workspace, including the expected source citation. The installed catalog exposed GPT-5.6 Luna; this runtime check used that model. Log: `build/context-live-fixture.log`.
- GPT-6 Luna subagents implemented the redesign; parent review identified and corrected transcript ordering, cancellation, restart, selection, and window-restoration issues.
- Development-signed 0.2.0 build succeeded and the installed app passed strict code-signature verification. Log: `build/context-redesign-build.log`.
- Native UI checks confirmed workspace/model discovery, accumulated demo transcript, exact passage selection, Stop retaining transcript/selection, and New clearing the synthetic conversation. The demo is isolated from model calls.

These checks establish local implementation behavior and a real provider path. They do not establish long-call audio quality or combined-source reliability.

## Real-call trial still required

Follow the README with one known workspace and Microphone first. Check whether semantic Context helps with a question whose wording differs from the source, whether useful prior understanding survives topic changes, and whether a selected-passage investigation adds evidence. Check capture ends on Stop while the conversation remains available.

Then separately trial Both with headphones. Long calls, remote participant capture, device changes, network interruption/recovery, and latency under sustained speech remain unproven until observed.

## Distribution boundary

The development app is locally signed. Older release ZIPs are not this build and remain unnotarized. The release script supports archive/export/notarization/stapling, but distribution readiness requires an actual accepted notarization result.

## Deferred

Raw audio recording, cloud sync, speaker diarization, calendar auto-join, meeting bots, SaaS connectors, external writes, task creation, and team administration.
