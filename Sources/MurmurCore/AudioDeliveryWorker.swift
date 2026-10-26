import Foundation

/// Capture callbacks enqueue synchronously; a single off-main consumer preserves order.
/// No task is created per audio chunk. The byte budget includes the in-flight send.
final class AudioDeliveryWorker: Sendable {
    static let defaultMaximumBytes = 24_000 * 2 * 2 // Two seconds of mono PCM16.
    private let mailbox: Mailbox
    private let task: Task<Void, Never>
    private let onOverflow: @Sendable () -> Void

    init(maximumBytes: Int = defaultMaximumBytes,
         send: @escaping @Sendable (Data) async -> Void,
         onOverflow: @escaping @Sendable () -> Void) {
        let mailbox = Mailbox(maximumBytes: maximumBytes)
        self.mailbox = mailbox
        self.onOverflow = onOverflow
        task = Task.detached(priority: .userInitiated) {
            for await _ in mailbox.wakeups {
                while !Task.isCancelled, let data = mailbox.take() {
                    guard !Task.isCancelled else { return }
                    await send(data)
                    mailbox.delivered(data.count)
                }
            }
        }
    }

    func enqueue(_ data: Data) {
        if mailbox.enqueue(data) {
            task.cancel()
            onOverflow()
        }
    }

    func cancel() {
        mailbox.close()
        task.cancel()
    }

    /// Join before reconnecting a shared transcription client: cancellation alone
    /// cannot retract an actor call already in flight.
    func stop() async {
        cancel()
        await task.value
    }

    deinit { mailbox.close(); task.cancel() }

    private final class Mailbox: @unchecked Sendable {
        // All mutable state is protected by lock. Continuation is thread-safe.
        private let lock = NSLock()
        private let maximumBytes: Int
        private var chunks: [Data] = []
        private var head = 0
        private var outstandingBytes = 0
        private var closed = false
        let wakeups: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init(maximumBytes: Int) {
            precondition(maximumBytes > 0)
            self.maximumBytes = maximumBytes
            (wakeups, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        }

        /// True only on the first overflow. Closed producers are ignored.
        func enqueue(_ data: Data) -> Bool {
            lock.withLock {
                guard !closed, !data.isEmpty else { return false }
                guard data.count <= maximumBytes - outstandingBytes else {
                    closeLocked()
                    return true
                }
                chunks.append(data)
                outstandingBytes += data.count
                continuation.yield(())
                return false
            }
        }

        func take() -> Data? {
            lock.withLock {
                guard !closed, head < chunks.count else { return nil }
                let data = chunks[head]
                head += 1
                if head >= 64 || head == chunks.count {
                    chunks.removeFirst(head)
                    head = 0
                }
                return data
            }
        }

        func delivered(_ bytes: Int) {
            lock.withLock { outstandingBytes = max(0, outstandingBytes - bytes) }
        }

        func close() { lock.withLock { closeLocked() } }

        private func closeLocked() {
            closed = true
            chunks.removeAll()
            head = 0
            outstandingBytes = 0
            continuation.finish()
        }
    }
}
