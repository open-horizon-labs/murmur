import Foundation
import XCTest
@testable import MurmurCore

final class ModelSelectionStoreTests: XCTestCase {
    func testArbitraryModelIDCanBeSavedWithoutBeingInCatalog() throws {
        let harness = try DefaultsHarness()
        defer { harness.cleanUp() }
        let store = ModelSelectionStore(userDefaults: harness.defaults)
        let customID = "provider/custom-model-v2"

        store.rememberContextModel(customID)
        store.rememberPassageModel("another-provider/long-reasoning")
        store.rememberPostCallModel("account-only/batch-transcription-2026")

        let relaunchedStore = ModelSelectionStore(userDefaults: harness.defaults)
        XCTAssertEqual(relaunchedStore.preferredContextModel, customID)
        XCTAssertEqual(relaunchedStore.preferredPassageModel, "another-provider/long-reasoning")
        XCTAssertEqual(relaunchedStore.preferredPostCallModel, "account-only/batch-transcription-2026")
        XCTAssertEqual(relaunchedStore.recentModels, ["account-only/batch-transcription-2026", "another-provider/long-reasoning", customID])
    }

    func testRecentModelsAreDeduplicatedAndBounded() throws {
        let harness = try DefaultsHarness()
        defer { harness.cleanUp() }
        let store = ModelSelectionStore(userDefaults: harness.defaults)

        for index in 0..<12 { store.rememberContextModel("org/model-\(index)") }
        store.rememberPassageModel("org/model-9")

        XCTAssertEqual(store.recentModels.count, 8)
        XCTAssertEqual(store.recentModels.first, "org/model-9")
        XCTAssertEqual(store.recentModels.filter { $0 == "org/model-9" }.count, 1)
        XCTAssertFalse(store.recentModels.contains("org/model-0"))
    }
}

private struct DefaultsHarness {
    let defaults: UserDefaults
    private let suiteName: String

    init() throws {
        suiteName = "ModelSelectionStoreTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw NSError(domain: "ModelSelectionStoreTests", code: 1)
        }
        defaults.removePersistentDomain(forName: suiteName)
        self.defaults = defaults
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
