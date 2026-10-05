# Temporary call audio and post-call review

Status: implemented, reviewed, and installed as 0.6.0 (12), 2026-09-30. See ../POSTCALL-REVIEW.md for evidence and verification boundaries.

## Decision

Retain local, source-separated audio temporarily while preserving live transcription and Context. After capture stops, produce a versioned final transcript and regenerate Context. Delete owned audio only after final results are durably saved, or after explicit deletion/retention expiry. Processing completion is not a guarantee of semantic correctness.

The alternatives were manual recovery from audio, continuous retranscription during capture, and text-only finalization. Post-call processing provides recovery without repeated work on the live path. Dissent highlighted silent semantic errors: preserve the live transcript, qualify uncertainty, and provide a bounded review-before-deletion option.

## Preservation constraints

- Live audio, agents, and UI remain independently scheduled. Disk writing cannot block the audio callback.
- Existing saved sessions remain readable; original transcript and investigation evidence are retained.
- Final results belong to an exact session and transcript version. Switching or resuming cannot receive a stale result.
- Microphone/system sources are not speaker identities. Capture gaps must remain visible.
- No changes to credentials, signing identities, or system Focus settings.
- Temporary audio expiry is enforced during app operation and on subsequent launch, not while the app is absent.
- Local deletion does not promise provider-side deletion.

## Execution checks

| Risk | Required adversarial check (rejects tempting shortcut) |
|---|---|
| Polished but wrong text | Known speech with numbers, negation, and closing corrections; do not judge only fluency. Human call accuracy remains an explicit verification boundary. |
| Missing/duplicated sources | Source-separated timeline fixture, overlap and silence; mixed output alone is not evidence of full coverage. |
| Live capture degradation | Bounded queue overflow and writer failure must report incomplete recording without blocking capture. |
| Lost recovery or early deletion | Interruption at recording, request, persistence and cleanup stages; API success alone cannot authorize deletion. |
| Invalidated citations | Original investigations resolve to original entries, final Context to final entries; no in-place replacement of identities. |
| Retention leak | Expiry, explicit deletion, restart and deletion-failure checks; failed cleanup cannot be reported as successful. |
| Stale post-call result | Stop/resume/session-switch lifecycle tests and durable save failure tests. |
| Provider incompatibility | Verify multipart API/model configuration and a bounded synthetic live check where existing authorized credential access permits it. |

## Release gate

Review implementation independently, run deterministic lifecycle/recording/provider-contract tests, verify signed build, preserve previous installed app, reinstall and verify launch. Do not claim real-call accuracy from synthetic tests. Record delivered behavior and actual evidence in the post-call implementation report.
