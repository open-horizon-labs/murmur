# Privacy and recording model

## What is retained

Audio is sent to OpenAI for live transcription while listening. Temporary recording is enabled by default and can be disabled in Settings. When enabled, selected microphone and system sources are saved separately in local WAV segments. After stopping, the recording is processed through the configured OpenAI batch transcription model, followed by Context analysis. This incurs additional API usage.

Temporary recordings are deleted after the post-call transcript and matching Context have been durably saved. Failed or pending work retains audio for retry, with a 24-hour expiry after stopping and a Delete now control. Keep until reviewed suppresses automatic success deletion but does not extend expiry. Interrupted capture recovery preserves the expiry recorded before the interruption. Expiry cleanup runs while Murmur is open and on its next launch; Murmur cannot perform cleanup while it is not running. Local deletion does not delete provider-side copies or operating-system backups. Processing completion does not guarantee transcription accuracy.

Murmur automatically saves conversations locally: the full transcript, latest Context, passage investigations, quoted selections, and cited source excerpts. Stop preserves the conversation; New conversation starts a separate one without deleting history. Reopening a saved conversation leaves listening paused and does not automatically run agents.

Session files and a previous recovery copy live under `~/Library/Application Support/me.openhorizons.murmur/Sessions`. They are not an app-encrypted vault. Temporary audio and its processing checkpoints live under `~/Library/Application Support/me.openhorizons.murmur/Recordings`, separately from session JSON; API keys and running tasks are not included in session files. A save indicator reports whether current content has been saved; speech not yet acknowledged as saved can be lost in a forced exit.

History provides rename, Markdown/JSON export, and delete controls. Delete removes Murmur's local session and recovery copy. It does not delete previously exported files, operating-system backups, or content already sent to configured providers. Exports contain transcript and workspace excerpts and should be shared deliberately.

Murmur persists up to eight recent workspace paths and the folders where agent consent was granted. Call-agent enablement is remembered separately; new calls do not automatically select a recent folder. A user-provided OpenAI API key is stored in macOS Keychain. A launch-environment key takes precedence and is not copied into preferences or Keychain.

## Agent access

Enabling call agents permits relevant text from the current call to be sent directly to OpenAI using the same API credential as transcription. Each run owns an immutable snapshot of that call and can navigate or search its full transcript through bounded tools. Automatic Context begins with a recent excerpt and prior understanding; investigations also receive the selected passage. A folder is accessible only when explicitly selected and authorized. Call-only runs receive no filesystem tools and cannot read other saved calls. These requests incur API usage. Disabling agents stops further work without deleting already displayed conversation data.

Agents receive read-only transcript tools, plus local list, search, and read tools only for an authorized folder. Each operation checks the selected workspace boundary and excluded secret/generated paths. Symlink traversal is denied. These application-level checks do not make Murmur an OS-sandboxed app, and filename exclusions cannot identify every secret that might appear in an ordinary source file. Only returned snippets may be cited as inspected evidence. Transcript evidence also requires matching session and entry IDs, exact excerpt text, and finalized speech; interrupted speech and system notices cannot be cited as settled statements. No agent shell, workspace writes, or arbitrary network tools are exposed.

Context requests set `store: false` and manage their bounded inputs in Murmur. This controls API response storage and does not assert zero provider retention; the configured service's data policies still apply. Murmur does not create hosted workspace indexes or upload whole folders.

The API credential is used for authentication only, and is not included in prompts, local tool results, preferences, session exports, or logs. Murmur does not send messages, purchase anything, or create external tasks through agents.

## Visible control

Listening starts only from an explicit action. The app shows the source and listening state. Stop ends capture and preserves the on-screen conversation; post-call processing may continue with visible progress. Investigations can run after Stop, with visible progress and cancellation controls.

The demo uses synthetic speech without microphone capture. No background listening, calendar auto-join, telemetry pipeline, or SaaS connector is included.
