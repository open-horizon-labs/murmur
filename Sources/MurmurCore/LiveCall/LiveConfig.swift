import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct LiveSettingsError: Error, LocalizedError, Sendable {
    public let field: String
    public let message: String
    public var errorDescription: String? { message }
}

/// The `live` section of settings.json. Nothing secret lives here: keys come from an environment variable or a command.
public struct LiveSettings: Sendable, Equatable {
    public var channels: [String] = ["mic", "system"]
    public var keepAudio = true
    public var language = "en-US"
    public var homelabURL = ""
    public var cloudFallback = false
    public var cloud = CloudASRConfig()
    public var llm = LLMConfig()

    public init() {}

    public static let defaultsJSON: JSONValue = [
        "channels": ["mic", "system"],
        "keep_audio": true,
        "language": "en-US",
        "asr": ["homelab_url": "", "cloud_fallback": false,
                "cloud": ["base_url": "https://api.openai.com/v1", "model": "gpt-transcribe", "key_env": "OPENAI_API_KEY", "key_command": []]],
        "llm": ["provider": "mercury", "base_url": "https://api.inceptionlabs.ai/v1", "model": "mercury-3",
                "reasoning_effort": "low", "key_env": "INCEPTION_API_KEY", "key_command": []]
    ]

    static func merge(_ base: JSONValue, _ overlay: JSONValue?) -> JSONValue {
        guard case .object(var result) = base, case .object(let over)? = overlay else { return overlay ?? base }
        for (key, value) in over {
            if case .object = value, case .object? = result[key] { result[key] = merge(result[key]!, value) } else { result[key] = value }
        }
        return .object(result)
    }

    public init(json: JSONValue) {
        let merged = Self.merge(Self.defaultsJSON, json)
        channels = (merged["channels"]?.arrayValue ?? []).compactMap(\.stringValue)
        keepAudio = merged["keep_audio"]?.boolValue ?? true
        language = merged["language"]?.stringValue ?? "en-US"
        let asr = merged["asr"]
        homelabURL = asr?["homelab_url"]?.stringValue ?? ""
        cloudFallback = asr?["cloud_fallback"]?.boolValue ?? false
        if let cloud = asr?["cloud"] {
            self.cloud.baseURL = cloud["base_url"]?.stringValue ?? self.cloud.baseURL
            self.cloud.model = cloud["model"]?.stringValue ?? self.cloud.model
            self.cloud.keyEnv = cloud["key_env"]?.stringValue ?? self.cloud.keyEnv
            self.cloud.keyCommand = (cloud["key_command"]?.arrayValue ?? []).compactMap(\.stringValue)
        }
        if let llm = merged["llm"] {
            self.llm.provider = llm["provider"]?.stringValue ?? "llm"
            self.llm.baseURL = llm["base_url"]?.stringValue ?? self.llm.baseURL
            self.llm.model = llm["model"]?.stringValue ?? self.llm.model
            let effort = llm["reasoning_effort"]?.stringValue ?? ""
            self.llm.reasoningEffort = effort.isEmpty ? nil : effort
            self.llm.keyEnv = llm["key_env"]?.stringValue ?? ""
            self.llm.keyCommand = (llm["key_command"]?.arrayValue ?? []).compactMap(\.stringValue)
            self.llm.timeout = llm["timeout"]?.doubleValue ?? 60
        }
    }

    /// settings.json under `root`, merged over the defaults. A missing or unreadable file means defaults.
    public static func load(root: URL) -> LiveSettings {
        let data = try? Data(contentsOf: root.appendingPathComponent("settings.json"))
        let file = data.flatMap { JSONValue.parse($0) }
        return LiveSettings(json: file?["live"] ?? [:])
    }

    public func validate() throws {
        if channels.isEmpty || !Set(channels).isSubset(of: ["mic", "system"]) {
            throw LiveSettingsError(field: "live.channels", message: "Choose microphone, system audio, or both.")
        }
        if !homelabURL.isEmpty,
           homelabURL.range(of: #"^wss?://[^\s/]+(:\d{1,5})?$"#, options: .regularExpression) == nil {
            throw LiveSettingsError(field: "live.asr.homelab_url", message: "Use an address like ws://host:8011.")
        }
        if !(llm.baseURL.hasPrefix("http://") || llm.baseURL.hasPrefix("https://")) {
            throw LiveSettingsError(field: "live.llm.base_url", message: "Use an http(s) address.")
        }
    }
}

public enum LiveConfig {
    /// Read KEY=VALUE lines into `env` without overriding values already set.
    public static func loadEnvFile(_ url: URL, into env: inout [String: String]) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            if env[key] == nil { env[key] = value }
        }
    }

    /// Load env files into the process environment (never overriding what is already set).
    public static func loadEnvFiles(_ urls: [URL]) {
        var env = ProcessInfo.processInfo.environment
        for url in urls { loadEnvFile(url, into: &env) }
        for (key, value) in env where ProcessInfo.processInfo.environment[key] == nil { setenv(key, value, 0) }
    }

    public static func buildASR(_ live: LiveSettings, env: [String: String]? = nil) throws -> ResilientASR {
        let env = env ?? ProcessInfo.processInfo.environment
        let url = (env["CALL_MEMORY_ASR_URL"]).flatMap { $0.isEmpty ? nil : $0 } ?? live.homelabURL
        let cloud: OpenAIASR? = live.cloudFallback ? OpenAIASR(live.cloud, language: live.language, env: env) : nil
        if !url.isEmpty { return ResilientASR(primary: HomelabASR(url: url, language: live.language), fallback: cloud) }
        if let cloud { return ResilientASR(primary: cloud, fallback: nil, retries: 1) }
        throw LiveSettingsError(field: "live.asr", message: "No transcription backend: set live.asr.homelab_url or enable the cloud fallback.")
    }

    /// A call session built from settings.json (and `env`, default the process environment). Recovers audio left by a
    /// crashed call first. A host app can pass an `env` that adds a key it looked up elsewhere (for example the Keychain).
    public static func makeSession(root: URL, env: [String: String]? = nil, sourceFactory: PCMSourceFactory? = nil) throws -> LiveSession {
        let env = env ?? ProcessInfo.processInfo.environment
        let live = LiveSettings.load(root: root)
        LiveStaging.recoverPartials(root: root)
        let asr = try buildASR(live, env: env)
        let agent = ContextAgent(client: ChatClient(live.llm, env: env))
        let homelab = !((env["CALL_MEMORY_ASR_URL"] ?? "").isEmpty && live.homelabURL.isEmpty)
        let host = live.llm.baseURL.components(separatedBy: "//").last?.components(separatedBy: "/").first ?? ""
        let provenance = ["heard": homelab ? "homelab ASR" : "cloud ASR", "notes": live.llm.model, "notes_host": host]
        return LiveSession(root: root, asr: asr, agent: agent, channels: live.channels, keepAudio: live.keepAudio,
                           sourceFactory: sourceFactory ?? { try ProcessPCMSource(kind: $0) }, provenance: provenance)
    }
}

// MARK: - Readiness

public enum LiveReadiness {
    static func row(_ id: String, _ label: String, _ state: String, _ detail: String, _ fix: String = "") -> JSONValue {
        ["id": .string(id), "label": .string(label), "state": .string(state), "detail": .string(detail), "fix": .string(fix)]
    }

    public static func checkCapture(channels: [String], platform: String? = nil) -> [JSONValue] {
        var rows: [JSONValue] = []
        for (kind, label) in [("mic", "Microphone"), ("system", "Call audio")] where channels.contains(kind) {
            let program: String
            do { program = try LiveCapture.sourceCommand(kind, platform: platform)[0] } catch {
                rows.append(row(kind, label, "fail", error.localizedDescription)); continue
            }
            if ProcessPCMSource.find(program) != nil {
                rows.append(row(kind, label, "ok", "Ready to capture."))
            } else if kind == "system" {
                let mac = (platform ?? LiveCapture.currentPlatform) == "darwin"
                rows.append(row(kind, label, "warn", "Not available. Only your microphone will be heard.",
                                mac ? "Rerun the installer on a Mac to build the capture helper." : "Install pulseaudio-utils (parec)."))
            } else {
                rows.append(row(kind, label, "fail", "\((program as NSString).lastPathComponent) is not installed.", "Install ffmpeg (Mac) or pulseaudio-utils (Linux)."))
            }
        }
        return rows
    }

    public static func checkASR(_ live: LiveSettings, env: [String: String]? = nil,
                                health: @Sendable (URL) async throws -> Data = LiveReadiness.fetchHealth) async -> JSONValue {
        let env = env ?? ProcessInfo.processInfo.environment
        let url = env["CALL_MEMORY_ASR_URL"].flatMap { $0.isEmpty ? nil : $0 } ?? live.homelabURL
        if url.isEmpty {
            if live.cloudFallback { return row("asr", "Transcription", "warn", "Using the cloud service. Audio leaves this network.") }
            return row("asr", "Transcription", "fail", "No transcription service is set.", "Set live.asr.homelab_url in settings.")
        }
        let hostPart = url.components(separatedBy: "://").last ?? url
        guard let healthURL = URL(string: "http://" + hostPart.trimmingTrailingSlashes + "/health"),
              let data = try? await health(healthURL), let info = JSONValue.parse(data) else {
            if live.cloudFallback { return row("asr", "Transcription", "warn", "Homelab service did not answer. Using the cloud fallback.") }
            return row("asr", "Transcription", "fail", "The transcription service did not answer.", "Check the homelab is on and you are on its network.")
        }
        if info["busy"]?.boolValue == true {
            return row("asr", "Transcription", "warn", "Another stream is using the service. Your speech is retried and may arrive late.")
        }
        return row("asr", "Transcription", "ok", "Homelab service ready. Audio stays on your network.")
    }

    public static func fetchHealth(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        return try await URLSession.shared.data(for: request).0
    }

    public static func checkLLM(_ live: LiveSettings, env: [String: String]? = nil) -> JSONValue {
        do { _ = try LiveKeys.resolve(keyEnv: live.llm.keyEnv, keyCommand: live.llm.keyCommand, env: env) } catch {
            return row("llm", "Notes", "fail", "No key for the notes model.", "Set \(live.llm.keyEnv.isEmpty ? "key_env" : live.llm.keyEnv) or key_command.")
        }
        let host = live.llm.baseURL.components(separatedBy: "//").last?.components(separatedBy: "/").first ?? ""
        return row("llm", "Notes", "ok", "\(live.llm.model) via \(host). Call text is sent there.")
    }

    public static func readiness(_ live: LiveSettings, env: [String: String]? = nil, platform: String? = nil,
                                 health: @Sendable (URL) async throws -> Data = LiveReadiness.fetchHealth) async -> JSONValue {
        let rows = checkCapture(channels: live.channels, platform: platform) + [await checkASR(live, env: env, health: health), checkLLM(live, env: env)]
        let canStart = !rows.contains { $0["state"]?.stringValue == "fail" }
        return ["rows": .array(rows), "can_start": .bool(canStart)]
    }
}
