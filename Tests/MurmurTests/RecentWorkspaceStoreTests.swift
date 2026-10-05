import Foundation
import XCTest
@testable import MurmurApp

@MainActor
final class RecentWorkspaceStoreTests: XCTestCase {
    func testRememberingPersistsMostRecentFirstAndDeduplicates() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let first = try harness.directory("first")
        let second = try harness.directory("second")
        let store = RecentWorkspaceStore(userDefaults: harness.defaults)

        _ = store.remember(first, openedAt: Date(timeIntervalSince1970: 10))
        _ = store.remember(second, openedAt: Date(timeIntervalSince1970: 20))
        _ = store.remember(first, openedAt: Date(timeIntervalSince1970: 30))

        let restored = RecentWorkspaceStore(userDefaults: harness.defaults).availableWorkspaces()
        XCTAssertEqual(restored.map(\.name), ["first", "second"])
        XCTAssertEqual(restored.first?.lastOpenedAt, Date(timeIntervalSince1970: 30))
    }

    func testHistoryIsBounded() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let store = RecentWorkspaceStore(userDefaults: harness.defaults, limit: 3)
        for index in 0..<5 {
            _ = store.remember(
                try harness.directory("workspace-\(index)"),
                openedAt: Date(timeIntervalSince1970: Double(index))
            )
        }

        XCTAssertEqual(
            store.availableWorkspaces().map(\.name),
            ["workspace-4", "workspace-3", "workspace-2"]
        )
    }

    func testMissingFoldersAreRemoved() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let existing = try harness.directory("existing")
        let removed = try harness.directory("removed")
        let store = RecentWorkspaceStore(userDefaults: harness.defaults)
        _ = store.remember(existing, openedAt: Date(timeIntervalSince1970: 10))
        _ = store.remember(removed, openedAt: Date(timeIntervalSince1970: 20))
        try FileManager.default.removeItem(at: removed)

        XCTAssertEqual(store.availableWorkspaces().map(\.name), ["existing"])
        XCTAssertNil(store.resolve(RecentWorkspace(
            path: removed.path,
            name: "removed",
            lastOpenedAt: .now
        )))
    }

    func testNewLaunchNeverSilentlyInheritsRecentWorkspace() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let first = try harness.workspace("first", body: "# First workspace\nRetry behavior lives here.")
        let second = try harness.workspace("second", body: "# Second workspace\nRelease notes live here.")
        let store = RecentWorkspaceStore(userDefaults: harness.defaults)
        _ = store.remember(first, openedAt: Date(timeIntervalSince1970: 10))
        _ = store.remember(second, openedAt: Date(timeIntervalSince1970: 20))

        let firstLaunch = AppModel(codexRuntime: NoopCodexRuntime(), userDefaults: harness.defaults)
        await firstLaunch.restoreLastWorkspaceIfNeeded()
        XCTAssertTrue(firstLaunch.isCallOnly)
        XCTAssertNil(firstLaunch.workspaceURL)

        let firstRecent = try XCTUnwrap(firstLaunch.recentWorkspaces.first { $0.name == "first" })
        await firstLaunch.switchToRecentWorkspace(firstRecent)
        XCTAssertEqual(firstLaunch.workspaceName, "first")

        let nextLaunch = AppModel(codexRuntime: NoopCodexRuntime(), userDefaults: harness.defaults)
        await nextLaunch.restoreLastWorkspaceIfNeeded()
        XCTAssertTrue(nextLaunch.isCallOnly)
        XCTAssertNil(nextLaunch.workspaceURL)
    }

}

private final class Harness {
    let defaults: UserDefaults
    let root: URL

    init() throws {
        let suite = "RecentWorkspaceStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-recents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func workspace(_ name: String, body: String) throws -> URL {
        let url = try directory(name)
        try body.write(
            to: url.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        return url
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor NoopCodexRuntime: CodexAppServerRuntime {
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
