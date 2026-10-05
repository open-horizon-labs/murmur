# Local session history

## Decision and scope

Option B: Murmur owns a local autosaved session library, backed by versioned per-session snapshots. Reliability during a real call is the first criterion; portability and a small interface follow. Direct API migration is a separate change.

The saved record includes the transcript, latest Context and its coverage/model, passage investigations and their selected quotes, source excerpts, and workspace reference. Credentials, runtime tasks, and raw audio must never be included. No cloud sync or full Context revision timeline is planned in this pass.

New conversation must preserve the previous session. Opening history must work offline and remain paused without starting microphone capture, model discovery, or paid agent work. Unfinished investigations become interrupted. Resume or retry is explicit.

## Review constraints

Superego and dissent supported this approach with these requirements:

- Keep storage DTOs separate from runtime objects and retain stable passage identities.
- Reject unsupported future formats without overwriting or silently downgrading them.
- Show Saved only for the latest acknowledged session revision.
- Serialize writes and deletion; delayed work must not recreate a deleted session.
- Recover from a validated previous snapshot without destroying that recovery copy.
- Surface write failures and prevent silent disposal of unsaved content.
- Atomic replacement prevents partially written snapshots; it does not promise recovery of speech that was never acknowledged as saved.

## Verification checklist

The following checks are required before this change is described as verified. Results will be recorded after implementation.

| Risk | Adversarial check | Shortcut this must reject |
| --- | --- | --- |
| Lost conversation after unexpected exit | Reopen saved content without Stop or normal shutdown; packaged-app restart smoke | Saving only on Stop/Quit |
| Stale saves overwrite newer speech | Deliver out-of-order revisions and verify newest durable content | Independent unguarded writes |
| Silent disk failure | Inject write failures, preserve unsaved current content, retry | Marking an attempted save as successful |
| Corrupt newest snapshot | Corrupt the primary, recover validated previous copy, then save again | Blindly rotating corrupt data into backup |
| Newer schema damage | Open/save against an unsupported future format | Treating all decoding failures as old/corrupt data |
| Deleted sessions return | Delete with saves/results pending, reopen with a new store | Removing only the visible row/file |
| Reopen requires services | Open offline with missing workspace and verify no capture/provider invocation | Reconstructing history by rerunning agents |
| Capture IDs collide after restart | Resume a recovered conversation using repeated provider item IDs | Reusing process-local numeric generations |
| Snapshot cost grows too much | Exercise long transcript and a large history fixture | Increasing save debounce to hide slow writes |
| Export loses useful content | Compare transcript, quotes, Context, source excerpts, metadata in JSON/Markdown | Exporting only the latest summary |

## Accepted boundaries

The latest Context is sufficient for this first version; next-day real-call use must confirm it. Local storage is not an app-encrypted vault. Delete applies to Murmur-managed files and recovery copies, not exported files, operating-system backups, or provider retention. Long-call usefulness and the preferred history workflow require human dogfooding.

## Verification results, 2026-09-29

The storage-focused suite passed 11 tests. It covers out-of-order revisions across store instances; recovery without overwriting a valid backup; future-schema rejection before full payload decoding; healthy, unavailable, and backup-only history rows; deletion tombstones; injected deletion failure and retry; I/O errors distinguished from corruption; a v1 fixture without optional provenance; complete structured export and readable Markdown; and runtime-to-storage conversion.

The initial measured run saved and loaded a 10,000-entry transcript in approximately 0.019 seconds each. Creating and listing 101 sessions took approximately 0.068 seconds. These are local fixture timings, not a long-call recording result.

The full Swift suite passed: 86 discovered tests, 81 passed, 5 opt-in checks skipped, no failures. Log: `build/persistence-tests.log`. Eleven AppModel persistence tests cover autosaving finalized speech without Stop, paused reopening without capture or provider discovery, bounded partial checkpoints, preserving history on New, failed saves preventing New/Open/Quit from discarding content, missing-workspace reopening, repeated provider IDs on resume, Context coverage, original investigation provenance, deletion with a late investigation result, retry after a committed save whose acknowledgement failed, and empty-capture suppression.

The storage recovery test also uses the same store instance to recover revision 1 after revision 2 is corrupted, then saves an edited revision 2. This catches a cached revision incorrectly rejecting edits to a recovered backup.

The signed 0.3.0 (build 5) app build passed and strict code-signature verification passed. Log: `build/persistence-build.log`. Installed 0.3.0 build 5 on 2026-09-29 after the Mac became available; verified its signature, launched it, and opened History. Packaged forced-exit/reopen and export checks remain unperformed; the user chose to install and proceed after the earlier 0.2.0 call crash.

### Risk disposition

| Risk | Disposition | Evidence |
| --- | --- | --- |
| Saving only at Stop/Quit | Retired by evidence | Live fake-transcription autosave test recovers content while the original model is still listening. |
| Stale revisions or deleted-session resurrection | Retired by evidence | Store tests reject old revisions across actors and tombstoned IDs after restart; AppModel ignores a late investigation result after deletion. |
| Silent save failure / unsaved discard | Retired by evidence | Failed saves block New/Open/Quit, retain content, and explicit retry advances the revision even when a write committed before its error. |
| Corruption or incompatible schema | Retired by evidence | Validated backup recovery, same-store recovery/edit, backup-only listing, and minimal future-schema envelope tests. |
| Reopening triggers capture or API work | Retired by evidence | AppModel tests assert zero audio connections, capture starts, discovery, and Context calls on open, including a missing workspace. |
| Capture identities collide | Retired by evidence | Resume test repeats provider item IDs while retaining prior entries; each capture uses a fresh UUID namespace. |
| Snapshot performance | Retired by evidence | 10,000-entry save/load and 101-session fixture timings above; filesystem serialization runs in the store actor. |
| Export loses transcript/evidence | Retired by evidence | Large-record JSON/Markdown checks retain transcript end, selected quote, question, and source excerpt. |
| Local deletion is universal erasure | Accepted with rationale | Only app-managed files are deleted; exports, system backups, and provider retention remain separate. |
| Latest Context/history workflow is useful on real calls | Accepted with rationale | Requires the user's next-day real-call trial; synthetic tests do not establish usefulness or audio reliability. |

The independent final lifecycle/superego review found no additional material concerns after the fixes. Native packaged forced-exit/reopen verification remains explicitly pending; installation, launch, and History availability were verified. These are distinct from the automated fixture claims above.
