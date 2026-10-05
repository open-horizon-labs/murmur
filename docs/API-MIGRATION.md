# Direct API agents and dynamic model selection

## Decision

Use OpenAI Responses for Context and selected-passage investigations. Keep the existing conversation lifecycle and local session archive. The model chooses when to list, search, or read bounded workspace files through Murmur-owned tools. No shell or external-write capability is exposed.

Alternatives considered: updating the installed Codex runtime would fix today's catalog but keep deployment coupled to CLI versions; hosted file search would add uploads, index synchronization, and cloud storage. A general multi-provider gateway is outside this personal native app's current need.

## Model discovery

Fetch `/v1/models` with the active credential. Use exact returned IDs and allow manual entry. Context and investigation choices are explicit and persistent. A refresh never changes the chosen model. A model missing from the latest list is visibly unlisted; an incompatible request reports its error without switching providers or models. No compiled reasoning-model catalog or model-name prefix filter is used. Audio transcription retains its existing endpoint-specific presets.

The API list contains availability metadata, not endpoint/tool/structured-output capability declarations. Therefore listing is not a compatibility claim. Search and recent choices keep the complete catalog usable without maintaining an allowlist. Production requests omit model-specific reasoning parameters.

## Dissent and accepted trade-offs

The strongest counterargument is that Codex already supplies a mature tool runtime. The migration is justified only if the bounded replacement still finds useful files from indirect conversational clues and keeps cancellation and retained Context reliable. Specialized Codex skills are not ported: this product requires read-only workspace recall, and the UI must not imply those skills remain available.

The first model selection requires user choice rather than an inferred "latest" default. Direct requests incur API usage. Application-level file checks are not an OS sandbox, and exclusions cannot identify arbitrary secrets embedded in ordinary source text.

## Required checks

- A future, unknown model ID returned by a test catalog appears without a source change. No default or fallback is invented.
- A selected ID survives refresh, restart, and disappearance from a catalog. Unsupported models fail visibly and retain previous Context.
- Synthetic Context and investigation calls retrieve the correct local file despite different transcript wording and retain source citations.
- Every read/search denies traversal, outside-root paths, symlinks, excluded files, oversized content, and invalid arguments. Ignore rules are conservative: case-insensitive and no negation can reopen an ignored path. An unreadable ignore policy denies access rather than assuming no exclusions.
- Evidence points only to snippets returned during that run. Unknown or fabricated references are removed.
- Stop, reset, credential replacement, and revocation reject stale results. Tool loops and network requests are bounded.
- Requests use `store: false`; tool continuations preserve all required response items. API keys never enter prompts, outputs, logs, preferences, or saved sessions.
- Existing saved-session behavior, microphone capture, transcript ordering, and save-before-quit handling remain covered by regression tests.

## Verification

Implementation and rollout checks are recorded in IMPLEMENTATION.md after execution. A synthetic provider check does not establish reliability on a long real call.
