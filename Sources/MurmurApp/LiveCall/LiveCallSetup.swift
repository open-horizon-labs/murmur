import Foundation
import MurmurCore

/// Wires the shared live-call core to this Mac: where its files live, where the notes key comes from, which capture it uses.
@MainActor
enum LiveCallSetup {
    static let notesKeychain = OpenAIKeychainStore(service: "me.openhorizons.murmur.live-notes", account: "notes-api-key")

    /// Same folder the Python tools use, so a call recorded here is picked up by the same sync.
    static var root: URL {
        if let override = ProcessInfo.processInfo.environment["CALL_MEMORY_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Call Memory", isDirectory: true)
    }

    /// Process environment, plus `<root>/.env` (a Finder-launched app has no shell environment), plus the notes key
    /// from the Keychain when neither the environment nor a key command provides one. The key is never written to settings.
    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        LiveConfig.loadEnvFile(root.appendingPathComponent(".env"), into: &env)
        let live = LiveSettings.load(root: root)
        let name = live.llm.keyEnv
        if !name.isEmpty, (env[name] ?? "").isEmpty, live.llm.keyCommand.isEmpty,
           let key = (try? notesKeychain.load()) ?? nil, !key.isEmpty {
            env[name] = key
        }
        return env
    }

    static func makeModel() -> LiveCallModel {
        let box = WeakModel()
        let model = LiveCallModel(
            makeSession: {
                let live = LiveSettings.load(root: root)
                let capture = MacLiveCapture(channels: live.channels) { message in
                    Task { @MainActor in box.model?.report(message) }
                }
                return try LiveConfig.makeSession(root: root, env: environment(), sourceFactory: { kind in try capture.source(for: kind) })
            },
            readiness: {
                let env = environment()
                let live = LiveSettings.load(root: root)
                let asr = await LiveReadiness.checkASR(live, env: env)
                let notes = LiveReadiness.checkLLM(live, env: env)
                return MacCaptureReadiness.rows(channels: live.channels) + [asr, notes].compactMap { ReadinessRow($0) }
            }
        )
        box.model = model
        return model
    }
}

@MainActor
private final class WeakModel {
    weak var model: LiveCallModel?
}
