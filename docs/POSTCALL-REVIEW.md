# Post-call recording and review — 0.6.0 (12)

## Delivered behavior

Murmur temporarily records the selected audio sources on a bounded writer queue. Stopping listening ends capture and starts batch transcription when models and agent consent are configured. The original live transcript stays available alongside the reviewed transcript. Final Context must inspect the complete settled transcript, and the exact transcript and Context must be saved before automatic audio deletion.

Recording failures, incomplete coverage, failed analysis, or failed persistence retain available audio for explicit retry. Keep until reviewed prevents success deletion; it does not extend the 24-hour expiry. Expiry cleanup runs during app operation and at subsequent launch. Interrupted capture recovery preserves the expiry already stored on disk. Source tracks do not identify individual speakers.

Model selection uses the fetched catalog and accepts custom model IDs. No fixed model list was introduced. The installed batch preference uses the API-verified `gpt-transcribe`; Context retains the existing choice.

## Review and verification

Luna 6 agents implemented recording, transcription, and app integration. Parent review found and corrected transcript-archive replacement on retry, interrupted-recovery retention extension, and active recording reconciliation. The independent superego review reported no concerns with the bounded approach and verification plan.

The first consolidated deterministic suite passed 158 tests, with 8 opt-in skips and no failures. It covers original-session compatibility, source ordering/mixing, queue limits, interrupted files, truncated files, checkpoints, cancellation, session switching, stop/resume, and persistence failure.

One signed-host synthetic API run transcribed a generated 24-second WAV and generated Context using the existing runtime credential. No private call audio was sent. Transcription retained all targeted details: 8–10 GPUs as an estimate pending load testing; no production access; weekly calls only if needed; Monday rather than Friday; Cloudflare still pending. Context preserved these distinctions, included uncertainty about the calendar date, and cited an exact inspected passage. Checkpoint reuse and session reopen assertions passed.

The live run exposed one presentation defect: internal transcript identifiers appeared in prose. The original live test therefore reports one failed assertion; the saved response is retained as evidence and used for an offline regression. API requests were not repeated merely to obtain a green run.

## Verification boundaries

Synthetic audio does not establish accented-English accuracy, speaker diarization, or long-call combined hardware capture quality. An earlier dogfood session has no recoverable raw audio from before this feature. Processing completion means the pipeline saved its results; it does not mean every statement is semantically correct.

## Rollout

Final deterministic regression: **160 tests, 8 opt-in skips, 0 failures** (`build/postcall-final-tests.log`). This includes the narrow final-review presentation replay and bare-ID regressions, plus the gated success-path save-before-deletion test. The last independent superego check reported no concerns.

The normal app build succeeded (`build/postcall-install-build.log`), and the installed application passed strict deep signature verification with the local Apple Development identity. The locally installed `Murmur.app` reports 0.6.0 (12); its executable hash matches the built artifact. Launch was verified at that installed path. The four existing saved-session/recovery JSON files remain present. No microphone capture was started during rollout.

Rollback application: `build/postcall-rollback/Murmur-0.5.0-build11.app`. Source baseline: `build/postcall-baseline/`. Credentials, signing identities, and Focus settings were not modified. The only rollout preference change selected the verified `gpt-transcribe` batch model; existing agent consent and Context selection remain as configured.
