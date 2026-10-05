import Foundation

/// Remembers whether Codex may inspect a selected workspace.
///
/// Consent is scoped to the workspace's canonical, symlink-resolved path. The
/// store persists only those paths; it never stores source contents or secrets.
@MainActor
final class WorkspaceConsentStore {
    static let defaultStorageKey = "codexWorkspaceConsentPaths"

    private let userDefaults: UserDefaults
    private let storageKey: String

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = WorkspaceConsentStore.defaultStorageKey
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
    }

    func hasConsent(for workspaceURL: URL) -> Bool {
        guard let identity = Self.workspaceIdentity(for: workspaceURL) else {
            return false
        }

        return consentedWorkspaceIdentities.contains(identity)
    }

    func grantConsent(for workspaceURL: URL) {
        guard let identity = Self.workspaceIdentity(for: workspaceURL) else {
            return
        }

        var identities = consentedWorkspaceIdentities
        identities.insert(identity)
        persist(identities)
    }

    func revokeConsent(for workspaceURL: URL) {
        guard let identity = Self.workspaceIdentity(for: workspaceURL) else {
            return
        }

        var identities = consentedWorkspaceIdentities
        identities.remove(identity)
        persist(identities)
    }

    static func workspaceIdentity(for workspaceURL: URL) -> String? {
        guard workspaceURL.isFileURL else {
            return nil
        }

        return workspaceURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    private var consentedWorkspaceIdentities: Set<String> {
        Set(userDefaults.stringArray(forKey: storageKey) ?? [])
    }

    private func persist(_ identities: Set<String>) {
        userDefaults.set(identities.sorted(), forKey: storageKey)
    }
}
