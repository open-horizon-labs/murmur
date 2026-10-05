import Foundation
import XCTest
@testable import MurmurApp

@MainActor
final class RecoveryTests: XCTestCase {
    func testRecoveryDropsUncertainAudioAndRejectsStaleEvents() async throws {
        let first = RecoveryFake(), second = RecoveryFake()
        let factory = RecoveryFactory([first, second]), events = RecoveryEvents()
        let client = RecoveringTranscriptionClient(delays: [.milliseconds(20)], factory: { factory.next() })
        try await client.connect(apiKey: "test", model: .live, context: "") { events.append($0) }
        await first.emit(.partial(itemID: "same", delta: "before"))
        try await eventually { events.values.contains { if case .partial = $0 { true } else { false } } }
        await first.emit(.transportLost)
        await first.emit(.transportLost) // Simultaneous send/receive failure.
        try await eventually { events.values.contains { if case .recovering = $0 { true } else { false } } }
        await client.send(audioPCM16: Data([1, 0]))
        try await eventually { events.values.contains(.recovered) }
        await first.emit(.completed(itemID: "same", text: "stale"))
        await second.emit(.completed(itemID: "same", text: "after"))
        await client.send(audioPCM16: Data([2, 0]))
        try await eventually { events.values.contains { if case .completed(_, "after") = $0 { true } else { false } } }
        XCTAssertFalse(events.values.contains { if case .completed(_, "stale") = $0 { true } else { false } })
        let ids = events.values.compactMap { event -> String? in
            switch event { case .partial(let id, _), .completed(let id, _): id; default: nil }
        }
        XCTAssertEqual(Set(ids).count, 2, "IDs must not collide across connections")
        let sent = await second.audio
        XCTAssertEqual(sent, [Data([2, 0])])
        XCTAssertEqual(factory.count, 2)
        await client.disconnect()
    }

    func testStopDuringBackoffPreventsReconnect() async throws {
        let first = RecoveryFake(), factory = RecoveryFactory([RecoveryFake()]), events = RecoveryEvents()
        let client = RecoveringTranscriptionClient(delays: [.seconds(60)], factory: { factory.count == 0 ? factory.take(first) : factory.next() })
        try await client.connect(apiKey: "test", model: .live, context: "") { events.append($0) }
        await first.emit(.transportLost)
        try await eventually { events.values.contains { if case .recovering = $0 { true } else { false } } }
        await client.disconnect()
        await first.emit(.transportLost)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(factory.count, 1)
        XCTAssertFalse(events.values.contains(.recovered))
    }

    func testRecoveryBudgetIsBoundedAndTransportErrorsAreClassified() async throws {
        let first = RecoveryFake()
        let failures = (0..<3).map { _ in RecoveryFake(error: URLError(.networkConnectionLost)) }
        let factory = RecoveryFactory([first] + failures), events = RecoveryEvents()
        let client = RecoveringTranscriptionClient(delays: [.zero, .zero, .zero], factory: { factory.next() })
        try await client.connect(apiKey: "test", model: .live, context: "") { events.append($0) }
        await first.emit(.transportLost)
        try await eventually { events.values.contains { if case .failed = $0 { true } else { false } } }
        XCTAssertEqual(factory.count, 4)
        XCTAssertFalse(events.values.contains(.recovered))
        XCTAssertTrue(RealtimeTransportFailure.isRecoverable(NSError(domain: NSPOSIXErrorDomain, code: 57)))
        XCTAssertFalse(RealtimeTransportFailure.isRecoverable(URLError(.userAuthenticationRequired)))
        XCTAssertFalse(RealtimeTransportFailure.isRecoverable(CancellationError()))
        XCTAssertFalse(RealtimeTransportFailure.isRecoverable(RealtimeError.sessionRejected("invalid model")))
        await client.disconnect()
    }

    func testProviderRejectionDoesNotConsumeFurtherRetries() async throws {
        let first = RecoveryFake(), denied = RecoveryFake(error: RealtimeError.sessionRejected("invalid model"))
        let factory = RecoveryFactory([first, denied]), events = RecoveryEvents()
        let client = RecoveringTranscriptionClient(delays: [.zero, .zero, .zero], factory: { factory.next() })
        try await client.connect(apiKey: "test", model: .live, context: "") { events.append($0) }
        await first.emit(.transportLost)
        try await eventually { events.values.contains { if case .failed = $0 { true } else { false } } }
        XCTAssertEqual(factory.count, 2)
        await client.disconnect()
    }

    func testInitialRejectionDoesNotRetry() async throws {
        let factory = RecoveryFactory([RecoveryFake(error: RealtimeError.sessionRejected("invalid key"))])
        let client = RecoveringTranscriptionClient(delays: [.zero], factory: { factory.next() })
        do {
            try await client.connect(apiKey: "test", model: .live, context: "") { _ in }
            XCTFail("Expected rejection")
        } catch { XCTAssertEqual(error as? RealtimeError, .sessionRejected("invalid key")) }
        XCTAssertEqual(factory.count, 1)
        await client.disconnect()
    }

    func testStoppedRecoveryHandshakeCannotReviveOrDisconnectNewSession() async throws {
        let first = RecoveryFake(), held = RecoveryFake(holdConnection: true), fresh = RecoveryFake()
        let factory = RecoveryFactory([first, held, fresh]), events = RecoveryEvents()
        let client = RecoveringTranscriptionClient(delays: [.zero], factory: { factory.next() })
        try await client.connect(apiKey: "test", model: .live, context: "") { events.append($0) }
        await first.emit(.transportLost)
        try await eventually { await held.hasPendingConnection }
        await client.disconnect()
        try await client.connect(apiKey: "test", model: .live, context: "") { events.append($0) }
        await held.releaseConnection()
        await held.emit(.completed(itemID: "old", text: "stale"))
        await fresh.emit(.completed(itemID: "new", text: "fresh"))
        try await eventually { events.values.contains { if case .completed(_, "fresh") = $0 { true } else { false } } }
        XCTAssertFalse(events.values.contains(.recovered))
        XCTAssertFalse(events.values.contains { if case .completed(_, "stale") = $0 { true } else { false } })
        await client.send(audioPCM16: Data([7, 0]))
        let audio = await fresh.audio
        XCTAssertEqual(audio, [Data([7, 0])])
        await client.disconnect()
    }

    private func eventually(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Condition did not become true")
    }
}

private actor RecoveryFake: RealtimeTranscribing {
    let error: (any Error)?
    var handler: (@Sendable (TranscriptionEvent) -> Void)?
    private(set) var audio: [Data] = []
    let holdConnection: Bool
    private var pendingConnection: CheckedContinuation<Void, Never>?
    var hasPendingConnection: Bool { pendingConnection != nil }
    init(error: (any Error)? = nil, holdConnection: Bool = false) { self.error = error; self.holdConnection = holdConnection }
    func releaseConnection() { pendingConnection?.resume(); pendingConnection = nil }
    func connect(apiKey: String, model: TranscriptionModel, context: String, eventHandler: @escaping @Sendable (TranscriptionEvent) -> Void) async throws {
        if let error { throw error }
        handler = eventHandler
        if holdConnection { await withCheckedContinuation { pendingConnection = $0 } }
    }
    func send(audioPCM16 data: Data) async { audio.append(data) }
    func disconnect() async {}
    func emit(_ event: TranscriptionEvent) { handler?(event) }
}

private final class RecoveryFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let clients: [RecoveryFake]
    private var used = 0
    var count: Int { lock.withLock { used } }
    init(_ clients: [RecoveryFake]) { self.clients = clients }
    func next() -> RecoveryFake {
        lock.withLock { defer { used += 1 }; return clients[min(used, clients.count - 1)] }
    }
    func take(_ client: RecoveryFake) -> RecoveryFake { lock.withLock { used += 1; return client } }
}

private final class RecoveryEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [TranscriptionEvent] = []
    var values: [TranscriptionEvent] { lock.withLock { events } }
    func append(_ event: TranscriptionEvent) { lock.withLock { events.append(event) } }
}
