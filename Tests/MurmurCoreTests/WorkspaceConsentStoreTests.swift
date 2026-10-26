import Foundation
import XCTest
@testable import MurmurCore

@MainActor
final class WorkspaceConsentStoreTests: XCTestCase {
    func testConsentPersistsAcrossStoreInstances() async throws {
        let (suiteName, userDefaults) = makeIsolatedDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let workspace = try makeTemporaryDirectory(named: "workspace")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let firstStore = makeStore(userDefaults: userDefaults)
        XCTAssertFalse(firstStore.hasConsent(for: workspace))

        firstStore.grantConsent(for: workspace)

        let relaunchedStore = makeStore(userDefaults: userDefaults)
        XCTAssertTrue(relaunchedStore.hasConsent(for: workspace))
    }

    func testCanonicalAndSymlinkPathsShareConsentIdentity() async throws {
        let (suiteName, userDefaults) = makeIsolatedDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let container = try makeTemporaryDirectory(named: "container")
        defer { try? FileManager.default.removeItem(at: container) }

        let workspace = container.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let symlink = container.appendingPathComponent("workspace-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: workspace)

        let store = makeStore(userDefaults: userDefaults)
        store.grantConsent(for: symlink)

        XCTAssertTrue(store.hasConsent(for: workspace))
        XCTAssertEqual(
            WorkspaceConsentStore.workspaceIdentity(for: workspace),
            WorkspaceConsentStore.workspaceIdentity(for: symlink)
        )
    }

    func testRevokingOneWorkspaceDoesNotRevokeAnother() async throws {
        let (suiteName, userDefaults) = makeIsolatedDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let firstWorkspace = try makeTemporaryDirectory(named: "first")
        let secondWorkspace = try makeTemporaryDirectory(named: "second")
        defer {
            try? FileManager.default.removeItem(at: firstWorkspace)
            try? FileManager.default.removeItem(at: secondWorkspace)
        }

        let store = makeStore(userDefaults: userDefaults)
        store.grantConsent(for: firstWorkspace)
        store.grantConsent(for: secondWorkspace)

        store.revokeConsent(for: firstWorkspace)

        XCTAssertFalse(store.hasConsent(for: firstWorkspace))
        XCTAssertTrue(store.hasConsent(for: secondWorkspace))
    }

    func testNonFileURLsCannotReceiveConsent() async {
        let (suiteName, userDefaults) = makeIsolatedDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let store = makeStore(userDefaults: userDefaults)
        let remoteURL = URL(string: "https://example.com/workspace")!

        store.grantConsent(for: remoteURL)

        XCTAssertFalse(store.hasConsent(for: remoteURL))
        XCTAssertNil(WorkspaceConsentStore.workspaceIdentity(for: remoteURL))
    }

    private func makeStore(userDefaults: UserDefaults) -> WorkspaceConsentStore {
        WorkspaceConsentStore(
            userDefaults: userDefaults,
            storageKey: "consent"
        )
    }

    private func makeIsolatedDefaults() -> (suiteName: String, userDefaults: UserDefaults) {
        let suiteName = "WorkspaceConsentStoreTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        return (suiteName, userDefaults)
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
