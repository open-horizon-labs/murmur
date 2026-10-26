import Foundation

public struct RecentWorkspace: Codable, Identifiable, Equatable, Sendable {
    public let path: String
    public let name: String
    public let lastOpenedAt: Date

    public var id: String { path }
    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

/// Persists lightweight workspace history for the current unsigned prototype.
/// Security-scoped bookmarks belong to the later signed, sandboxed app target.
@MainActor
final class RecentWorkspaceStore {
    static let defaultStorageKey = "recentWorkspaces"

    private let userDefaults: UserDefaults
    private let storageKey: String
    private let limit: Int
    private let fileManager: FileManager

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = RecentWorkspaceStore.defaultStorageKey,
        limit: Int = 8,
        fileManager: FileManager = .default
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.limit = max(1, limit)
        self.fileManager = fileManager
    }

    func availableWorkspaces() -> [RecentWorkspace] {
        let available = storedWorkspaces.filter { isReadableDirectory($0.url) }
        if available != storedWorkspaces { persist(available) }
        return available
    }

    @discardableResult
    func remember(_ url: URL, openedAt: Date = .now) -> [RecentWorkspace] {
        guard let path = canonicalPath(url), isReadableDirectory(URL(fileURLWithPath: path)) else {
            return availableWorkspaces()
        }

        let workspace = RecentWorkspace(
            path: path,
            name: URL(fileURLWithPath: path).lastPathComponent,
            lastOpenedAt: openedAt
        )
        var updated = storedWorkspaces.filter { $0.path != path && isReadableDirectory($0.url) }
        updated.append(workspace)
        updated.sort { $0.lastOpenedAt > $1.lastOpenedAt }
        updated = Array(updated.prefix(limit))
        persist(updated)
        return updated
    }

    @discardableResult
    func remove(_ url: URL) -> [RecentWorkspace] {
        guard let path = canonicalPath(url) else { return availableWorkspaces() }
        let updated = storedWorkspaces.filter { $0.path != path && isReadableDirectory($0.url) }
        persist(updated)
        return updated
    }

    func resolve(_ workspace: RecentWorkspace) -> URL? {
        guard isReadableDirectory(workspace.url) else {
            _ = remove(workspace.url)
            return nil
        }
        return workspace.url
    }

    private var storedWorkspaces: [RecentWorkspace] {
        guard let data = userDefaults.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([RecentWorkspace].self, from: data)) ?? []
    }

    private func persist(_ workspaces: [RecentWorkspace]) {
        guard let data = try? JSONEncoder().encode(workspaces) else { return }
        userDefaults.set(data, forKey: storageKey)
    }

    private func canonicalPath(_ url: URL) -> String? {
        guard url.isFileURL else { return nil }
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func isReadableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && fileManager.isReadableFile(atPath: url.path)
    }
}
