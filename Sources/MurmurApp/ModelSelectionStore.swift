import Foundation

/// Stores a user's preferred OpenAI model IDs for new conversations.
/// Session-specific model IDs continue to live in SavedSession.
struct ModelSelectionStore {
    private let defaults: UserDefaults
    private let contextKey = "murmur.agent.contextModel"
    private let passageKey = "murmur.agent.passageModel"
    private let postCallKey = "murmur.transcription.postCallModel"
    private let recentsKey = "murmur.agent.recentModels"

    init(userDefaults: UserDefaults = .standard) {
        defaults = userDefaults
    }

    var preferredContextModel: String? { nonEmpty(defaults.string(forKey: contextKey)) }
    var preferredPassageModel: String? { nonEmpty(defaults.string(forKey: passageKey)) }
    var preferredPostCallModel: String? { nonEmpty(defaults.string(forKey: postCallKey)) }
    var recentModels: [String] { defaults.stringArray(forKey: recentsKey) ?? [] }

    func rememberContextModel(_ model: String) {
        store(model, forKey: contextKey)
    }

    func rememberPassageModel(_ model: String) {
        store(model, forKey: passageKey)
    }

    func rememberPostCallModel(_ model: String) {
        store(model, forKey: postCallKey)
    }

    func rememberChoice(_ model: String) {
        guard let value = nonEmpty(model) else { return }
        var recents = recentModels.filter { $0 != value }
        recents.insert(value, at: 0)
        defaults.set(Array(recents.prefix(8)), forKey: recentsKey)
    }

    private func store(_ value: String, forKey key: String) {
        guard let value = nonEmpty(value) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(value, forKey: key)
        rememberChoice(value)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Main-actor boundary for reading the existing Keychain credential from an
/// async, Sendable API-key provider closure.
@MainActor
final class OpenAIAPIKeyProvider: Sendable {
    private let credentialStore: any TranscriptionCredentialStore
    private let environmentKey: String?

    init(credentialStore: any TranscriptionCredentialStore, environmentKey: String?) {
        self.credentialStore = credentialStore
        self.environmentKey = environmentKey
    }

    func load() throws -> String {
        if let environmentKey, !environmentKey.isEmpty { return environmentKey }
        guard let key = try credentialStore.load(), !key.isEmpty else {
            throw OpenAIAPIKeyProviderError.missingKey
        }
        return key
    }
}

enum OpenAIAPIKeyProviderError: LocalizedError {
    case missingKey

    var errorDescription: String? { "Add an OpenAI API key in Settings to use workspace agents." }
}
