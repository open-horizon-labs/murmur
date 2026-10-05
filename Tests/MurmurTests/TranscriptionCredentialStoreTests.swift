import Foundation
import XCTest
@testable import MurmurApp

@MainActor
final class TranscriptionCredentialStoreTests: XCTestCase {
    func testAppModelCredentialLifecycleAndEnvironmentPrecedence() {
        let store = MemoryCredentialStore()
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite(defaults)) }

        let firstLaunch = AppModel(
            codexRuntime: CredentialNoopRuntime(),
            userDefaults: defaults,
            credentialStore: store
        )
        XCTAssertFalse(firstLaunch.hasTranscriptionCredential)
        XCTAssertFalse(firstLaunch.saveTranscriptionAPIKey("   "))
        XCTAssertTrue(firstLaunch.saveTranscriptionAPIKey("  saved-value  "))
        XCTAssertEqual(store.value, "saved-value")

        let nextLaunch = AppModel(
            codexRuntime: CredentialNoopRuntime(),
            userDefaults: defaults,
            credentialStore: store
        )
        XCTAssertTrue(nextLaunch.hasSavedTranscriptionCredential)
        XCTAssertEqual(nextLaunch.resolvedTranscriptionAPIKey(), "saved-value")

        let environmentLaunch = AppModel(
            codexRuntime: CredentialNoopRuntime(),
            userDefaults: defaults,
            credentialStore: store,
            launchAPIKey: "environment-value"
        )
        XCTAssertTrue(environmentLaunch.usesEnvironmentCredential)
        XCTAssertEqual(environmentLaunch.resolvedTranscriptionAPIKey(), "environment-value")

        nextLaunch.removeTranscriptionAPIKey()
        XCTAssertNil(store.value)
        let finalLaunch = AppModel(
            codexRuntime: CredentialNoopRuntime(),
            userDefaults: defaults,
            credentialStore: store
        )
        XCTAssertFalse(finalLaunch.hasTranscriptionCredential)
    }

    func testSignedHostKeychainSaveRelaunchAndRemoveWhenExplicitlyEnabled() throws {
        guard ProcessInfo.processInfo.environment["MURMUR_SIGNED_HOST_SMOKE"] == "1" else {
            throw XCTSkip("Set MURMUR_SIGNED_HOST_SMOKE=1 to exercise a temporary Keychain item.")
        }

        let identifier = UUID().uuidString
        let store = OpenAIKeychainStore(
            service: "me.openhorizons.murmur.tests.\(identifier)",
            account: "signed-host-smoke"
        )
        try? store.delete()
        defer { try? store.delete() }

        try store.save("temporary-smoke-value")
        XCTAssertEqual(try store.load(), "temporary-smoke-value")
        let relaunchedStore = OpenAIKeychainStore(
            service: "me.openhorizons.murmur.tests.\(identifier)",
            account: "signed-host-smoke"
        )
        XCTAssertEqual(try relaunchedStore.load(), "temporary-smoke-value")
        try relaunchedStore.delete()
        XCTAssertNil(try store.load())
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "TranscriptionCredentialStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(suite, forKey: "test-suite-name")
        defaults.removePersistentDomain(forName: suite)
        defaults.set(suite, forKey: "test-suite-name")
        return defaults
    }

    private func defaultsSuite(_ defaults: UserDefaults) -> String {
        defaults.string(forKey: "test-suite-name")!
    }
}

private final class MemoryCredentialStore: TranscriptionCredentialStore {
    var value: String?

    func load() throws -> String? { value }
    func save(_ apiKey: String) throws { value = apiKey }
    func delete() throws { value = nil }
}

private actor CredentialNoopRuntime: CodexAppServerRuntime {
    nonisolated let events = AsyncStream<CodexAppServerEvent> { $0.finish() }

    func start() async throws {}
    func listModels() async throws -> [CodexModel] { [] }
    func listSkills(in workspace: URL, forceReload: Bool) async throws -> CodexSkillsInventory {
        CodexSkillsInventory(skills: [], errors: [])
    }
    func startThread(_ configuration: CodexThreadConfiguration) async throws -> CodexThread {
        CodexThread(id: "unused", model: "unused", workspace: configuration.workspace.path)
    }
    func startTurn(_ configuration: CodexTurnConfiguration) async throws -> CodexTurn {
        CodexTurn(id: "unused", status: "completed")
    }
    func interrupt(threadID: String, turnID: String) async throws {}
    func stop() async {}
}
