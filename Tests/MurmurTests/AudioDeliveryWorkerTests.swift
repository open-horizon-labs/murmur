import Foundation
import XCTest
@testable import MurmurApp

@MainActor
final class AudioDeliveryWorkerTests: XCTestCase {
    func testAudioDrainsWhileMainActorIsBlocked() {
        let delivered = DispatchSemaphore(value: 0)
        let worker = AudioDeliveryWorker(send: { _ in delivered.signal() }, onOverflow: {})
        defer { worker.cancel() }
        worker.enqueue(Data(repeating: 1, count: 480))
        // Deliberately block the UI executor. An inherited-main Task cannot pass.
        XCTAssertEqual(delivered.wait(timeout: .now() + 2), .success)
    }

    func testChunkOrderAndLateProducerAfterStop() async {
        let recorder = AudioRecorder()
        let delivered = expectation(description: "ordered chunks")
        delivered.expectedFulfillmentCount = 100
        let worker = AudioDeliveryWorker(send: { data in
            recorder.append(data)
            delivered.fulfill()
        }, onOverflow: {})
        let input = (0..<100).map { Data(repeating: UInt8($0), count: 48) }
        for chunk in input { worker.enqueue(chunk) }
        await fulfillment(of: [delivered], timeout: 2)
        await worker.stop()
        worker.enqueue(Data([255]))
        XCTAssertEqual(recorder.values, input)
    }

    func testBudgetIncludesInflightAudioAndOverflowIsReportedOnce() async {
        let gate = AudioSendGate()
        let failures = AudioRecorder()
        let worker = AudioDeliveryWorker(maximumBytes: 10, send: { data in
            await gate.send(data)
        }, onOverflow: { failures.append(Data([1])) })
        worker.enqueue(Data(repeating: 1, count: 6))
        await gate.waitForSend()
        worker.enqueue(Data(repeating: 2, count: 4)) // Exactly the byte budget.
        XCTAssertEqual(failures.values.count, 0)
        worker.enqueue(Data([3]))
        for _ in 0..<100 { worker.enqueue(Data([4])) }
        XCTAssertEqual(failures.values.count, 1)
        await gate.release()
        await worker.stop()
        let values = await gate.values
        XCTAssertEqual(values, [Data(repeating: 1, count: 6)])
    }

    func testStopJoinsInflightSendAndDiscardsPendingAudio() async {
        let gate = AudioSendGate()
        let finished = AudioRecorder()
        let worker = AudioDeliveryWorker(send: { await gate.send($0) }, onOverflow: {})
        worker.enqueue(Data([1]))
        await gate.waitForSend()
        worker.enqueue(Data([2]))
        worker.cancel()
        let stop = Task { await worker.stop(); finished.append(Data([1])) }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(finished.values.isEmpty, "Stop must wait for the old send before reconnect")
        worker.enqueue(Data([3]))
        await gate.release()
        await stop.value
        let values = await gate.values
        XCTAssertEqual(values, [Data([1])])
        XCTAssertEqual(finished.values.count, 1)
    }
}

private final class AudioRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []
    var values: [Data] { lock.withLock { storage } }
    func append(_ data: Data) { lock.withLock { storage.append(data) } }
}

private actor AudioSendGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var values: [Data] = []

    func send(_ data: Data) async {
        values.append(data)
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }
    func waitForSend() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { continuation?.resume(); continuation = nil }
}
