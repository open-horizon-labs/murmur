import AVFoundation
import CoreGraphics
import Foundation
import MurmurCore

/// Feeds the shared live-call session from the existing ScreenCaptureKit capture (`AudioCaptureCoordinator`).
///
/// The coordinator already converts both ScreenCaptureKit outputs to 24 kHz mono PCM16 and, through its
/// `recordingHandler`, hands over each source *before* mixing. That is exactly what the call needs: the microphone
/// is "me", system audio is "them". This type only resamples 24 kHz to 16 kHz (the recognizer's rate) and exposes
/// one `PCMSource` per channel. The session mixes the two channels for the saved recording itself (core `Mixer`).
final class MacLiveCapture: @unchecked Sendable {
    private let coordinator = AudioCaptureCoordinator()
    private let channels: [String]
    private let onFailure: @Sendable (String) -> Void
    private let lock = NSLock()
    private var sources: [String: QueuePCMSource] = [:]
    private var resamplers: [String: LinearResampler] = [:]
    private var started = false
    private var ended = false

    init(channels: [String], onFailure: @escaping @Sendable (String) -> Void) {
        self.channels = channels
        self.onFailure = onFailure
        for kind in channels {
            resamplers[kind] = LinearResampler(from: 24_000, to: 16_000)
            sources[kind] = QueuePCMSource(
                onStart: { [weak self] in self?.beginCapture() },
                onStop: { [weak self] in self?.endCapture() }
            )
        }
    }

    func source(for kind: String) throws -> any PCMSource {
        guard let source = lock.withLock({ sources[kind] }) else { throw MacLiveCaptureError.unknownChannel(kind) }
        return source
    }

    private var mode: AudioSourceMode {
        switch (channels.contains("mic"), channels.contains("system")) {
        case (true, true): .both
        case (true, false): .microphone
        default: .system
        }
    }

    /// Called by each source's `start()`; only the first call starts capture.
    private func beginCapture() {
        let shouldStart = lock.withLock { () -> Bool in
            guard !started, !ended else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }
        let mode = self.mode
        Task { [weak self] in
            guard let self else { return }
            do {
                try await coordinator.start(
                    mode: mode,
                    audioHandler: { _ in },   // the mixed 24 kHz stream is not used; each source is taken unmixed below
                    errorHandler: { [weak self] message in self?.fail(message) },
                    recordingSessionID: UUID(),
                    recordingHandler: { [weak self] _, source, data, _ in self?.deliver(source, data) }
                )
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    private func deliver(_ source: AudioRecordingSource, _ data: Data) {
        let kind = source == .microphone ? "mic" : "system"
        let output: (QueuePCMSource, Data)? = lock.withLock {
            guard !ended, let queue = sources[kind], var resampler = resamplers[kind] else { return nil }
            let converted = resampler.process(data)
            resamplers[kind] = resampler
            return (queue, converted)
        }
        if let (queue, converted) = output, !converted.isEmpty { queue.push(converted) }
    }

    private func endCapture() {
        let finished = lock.withLock { () -> [QueuePCMSource]? in
            guard !ended else { return nil }
            ended = true
            return Array(sources.values)
        }
        guard let finished else { return }
        for source in finished { source.finish() }
        Task { [coordinator] in await coordinator.stop() }
    }

    private func fail(_ message: String) {
        let first = lock.withLock { () -> Bool in
            guard !ended else { return false }
            ended = true
            return true
        }
        guard first else { return }
        onFailure("Could not capture call audio: \(message)")
        for source in lock.withLock({ Array(sources.values) }) { source.finish() }
    }
}

enum MacLiveCaptureError: LocalizedError {
    case unknownChannel(String)

    var errorDescription: String? {
        switch self {
        case .unknownChannel(let kind): "No \(kind) capture channel is configured."
        }
    }
}

/// Readiness rows for the idle screen: macOS permissions instead of the Linux `parec` check.
enum MacCaptureReadiness {
    static func rows(channels: [String]) -> [ReadinessRow] {
        var rows: [ReadinessRow] = []
        if channels.contains("mic") {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                rows.append(ReadinessRow(id: "mic", label: "Microphone", state: .ok, detail: "Ready to capture."))
            case .notDetermined:
                rows.append(ReadinessRow(id: "mic", label: "Microphone", state: .ok, detail: "macOS asks for access when the call starts."))
            default:
                rows.append(ReadinessRow(id: "mic", label: "Microphone", state: .fail, detail: "Microphone access is off for Murmur.",
                                         fix: "Allow it in System Settings > Privacy & Security > Microphone."))
            }
        }
        if channels.contains("system") {
            if CGPreflightScreenCaptureAccess() {
                rows.append(ReadinessRow(id: "system", label: "Call audio", state: .ok, detail: "Ready to capture."))
            } else {
                rows.append(ReadinessRow(id: "system", label: "Call audio", state: .warn,
                                         detail: "Needs Screen & System Audio Recording access. Until you allow it, only your microphone will be heard.",
                                         fix: "Allow it in System Settings > Privacy & Security > Screen & System Audio Recording, then restart Murmur."))
            }
        }
        return rows
    }
}
