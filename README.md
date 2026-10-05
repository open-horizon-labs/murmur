# Murmur

Murmur is a native macOS companion that listens to a meeting and quietly surfaces the most relevant context from the conversation and an optional selected folder. It provides live context and a post-call review, with temporary local audio for recovery.

The current dogfood build provides:

- a native SwiftUI companion window;
- system-audio, microphone, and combined source modes;
- a ScreenCaptureKit audio boundary for any Mac meeting source;
- an OpenAI Realtime transcription client with live and accuracy-focused models;
- a native folder picker and bounded code-aware workspace index;
- direct OpenAI Responses API agents with live model discovery and remembered model choices;
- a full timestamped transcript beside an evolving, call-informed Context;
- coalesced automatic Context updates and explicit, cancellable passage investigations;
- consent remembered once per canonical workspace;
- call-only defaults and an eight-item recent-workspace switcher;
- a synthetic demo without microphone capture or model calls.

## Run Murmur

Requires macOS 15+, Xcode with Swift 6, and XcodeGen. For a signed build, copy `Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig` and set your Apple Developer team. This local file is ignored by Git; certificates remain in your Keychain.

Generate the Xcode project and build a development-signed app:

```sh
./Scripts/build-app.sh
open build/DerivedData/Build/Products/Debug/Murmur.app
```

For an unsigned compilation check, run `./Scripts/build-app.sh CODE_SIGNING_ALLOWED=NO`. Run offline tests with `swift test -j 2`; live provider tests are opt-in and require explicit model environment variables.

You can also open `Murmur.xcodeproj` and run the `Murmur` scheme. The project is generated from `project.yml`; edit that file rather than hand-editing project settings.

The Finder-launched app accepts an OpenAI API key in Settings and stores it in macOS Keychain. During command-line development, `OPENAI_API_KEY` still takes precedence without being copied into Keychain:

```sh
OPENAI_API_KEY=... swift run Murmur
```

Choose **Try demo meeting** to see a synthetic conversation without live audio. The demo shows labeled sample Context and makes no model calls.

New conversations start in **Call only**. Enable call agents in Settings → Context and choose your models, then start listening explicitly. No folder is required or inherited from a previous call. To add file context before starting, choose **Add folder…** and select a code repository or document folder. Murmur indexes common source, config, manifest, Markdown, and text files in memory; it skips secrets, hidden/build/vendor folders, files over 1 MB, `.gitignore` matches, and anything after the first 2,000 chunks.

Enable call agents for transcript-only Context and investigations, or grant the selected folder access for workspace-assisted calls. Murmur loads the current model catalog directly from OpenAI and remembers consent for that canonical folder. Choose a model explicitly for each role using the searchable selector or a model ID. Choices are remembered; refreshing the catalog never silently substitutes another model. The catalog does not report workflow compatibility, so incompatible selections produce a visible error. Context updates automatically from completed speech, independent of keyword matches. Each run receives an immutable snapshot of this call, a bounded recent excerpt, and the previous understanding. Read and search tools let it inspect earlier passages; transcript citations link back to the inspected words. Spoken claims are not independently verified facts. Highlight transcript text and choose **Investigate** for a focused, cancellable follow-up.

Context and passage findings render Markdown as structured native text using Textual: paragraph breaks, headings, nested lists, tables, blockquotes, and code blocks retain their layout. Text is selectable; file and transcript navigation remains in the validated source rows. Generated image URLs are not fetched.

**Settings → Context → Context instructions** lets you edit the tone, structure, and focus of live and post-call notes. Save applies the guidance to the next Context update across calls on this Mac; it does not rerun analysis or change an in-flight request. Restore default returns to the built-in guidance. Citation validation and transcript-reading requirements remain fixed.

Context defaults to 30 lookup rounds, 120 transcript/file tool calls, and a five-minute overall deadline. Settings → Advanced → Context limits lets you save these limits on this Mac or restore defaults; changes apply to the next live or post-call update, leaving running updates unchanged. Allowed ranges are 1–100 rounds, 1–1,000 tool calls, and 30–1,800 seconds. A summary-only response is reserved when either lookup limit is reached, within the overall deadline. Passage investigations retain 30 rounds, 120 tool calls, and their two-minute deadline. Final post-call review still requires full transcript coverage before audio can be deleted.

Transcription, Context, and investigations use the same OpenAI API credential and incur API usage. Call-only agents can read and search only this call’s transcript snapshot. Folder-authorized agents can also list, search, and read bounded workspace files through local tools. They cannot execute commands or write files. File access applies workspace boundaries and exclusions to each operation, and displayed evidence is checked against snippets actually returned to the agent.

The **Transcription model** control offers:

- **Live** (`gpt-live-transcribe`) for low-latency partial text while someone is speaking.
- **Accurate** (`gpt-transcribe`) for transcription after each locally detected speech turn.

The direct-download MVP stores a user-provided OpenAI API key in Keychain; no credential is included in the app or its preferences. A short-lived credential broker remains an option if Murmur becomes a hosted multi-user product.

The native app has a stable bundle identity, permission descriptions, hardened runtime, and separate Apple Development and Developer ID signing configurations. It is intentionally not App-Sandboxed in this direct-download slice so selected local workspaces remain accessible.

## First Context trial

1. Choose a small workspace whose contents you know and enable workspace agents. Check the Context and investigation model selections.
2. Add your OpenAI API credential in the app if needed. Select **Microphone** and **Live**, then **Start listening**.
3. Speak several related sentences, pausing between them. Mention a decision, a constraint, and a question that the workspace can answer.
4. Confirm the full transcript accumulates, Context finds useful file evidence, and earlier useful context remains when later speech arrives.
5. Select a passage, choose **Investigate**, and ask a focused question. Verify its answer and source.
6. **Stop** and confirm capture ends while transcript and results remain visible. Investigations can still run after Stop. **Resume** continues the conversation; **New conversation** starts a separate saved session.

Transcription and agent turns use the configured providers and consume usage. Microphone mode records what the microphone hears; headphones help isolate a first trial. To capture remote participants directly, Mac audio or Both needs a separate real-call check.

Conversations are automatically saved locally. **History** reopens them paused and offers rename, Markdown/JSON export, and delete controls. **New conversation** preserves the previous session. With temporary recording enabled, Murmur keeps selected audio sources locally while listening and uses them for a post-call transcript and Context. The original live transcript remains available. Audio is deleted after the final result is saved, unless held for review, and otherwise expires after 24 hours. Cleanup runs while the app is open and on its next launch. The demo is synthetic and does not prove live audio quality. See [local session history](docs/PERSISTENCE.md) for recovery and retention boundaries.

## Direct-download release

A release requires your own Developer ID Application certificate, Apple Developer team, and a one-time `notarytool` Keychain profile:

```sh
xcrun notarytool store-credentials "murmur-notary" --apple-id "YOUR_APPLE_ID" --team-id "YOUR_TEAM_ID" --password "YOUR_APP_SPECIFIC_PASSWORD"
MURMUR_DEVELOPMENT_TEAM=YOUR_TEAM_ID MURMUR_NOTARY_PROFILE=murmur-notary ./Scripts/release.sh
```

The release script archives, exports, submits, waits for Apple, staples the ticket, validates Gatekeeper acceptance, and creates `build/Murmur.zip`. Credentials stay in Keychain and are never read by the script.

## Product docs

- [Product and MVP](docs/PRODUCT.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Privacy model](docs/PRIVACY.md)
- [Implementation plan](docs/IMPLEMENTATION.md)

## Current boundary

Microphone transcription and local file recall were verified in the earlier 0.1.2 trial. The Transcript/Context experience adds semantic agent work and local session history. Build and deterministic tests do not establish long-call reliability. Combined audio, device changes, and network recovery still need real-device trials. No diarization, cloud sync, SaaS connector, or external write action is included.

Reasoning effort is configurable independently beside the Context and passage investigation model selectors. Both start at **Model default**, which omits `reasoning.effort` and preserves the API default. Explicit choices are sent on every tool and summary turn. Supported values depend on the model; Murmur surfaces provider errors without silently changing the model or effort. Preferences are saved on this Mac and captured when the next run starts. Transcription is unaffected. Higher effort still operates within the existing time and output-token limits.
