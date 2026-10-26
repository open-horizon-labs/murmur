import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Bounded, thread-safe event queue for SSE subscribers. Drops events when full rather than blocking the call.
public final class EventQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var items: [JSONValue] = []
    private let capacity: Int

    public init(capacity: Int = 500) { self.capacity = capacity }

    public func put(_ event: JSONValue) {
        condition.lock()
        if items.count < capacity { items.append(event); condition.signal() }
        condition.unlock()
    }

    /// Next event, or nil after `timeout` seconds.
    public func get(timeout: TimeInterval) -> JSONValue? {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while items.isEmpty {
            if !condition.wait(until: deadline) { return nil }
        }
        return items.removeFirst()
    }
}

/// Staging of a finished call as a normal recording: `incoming/live-<host>/<id>.wav` + manifest.
public enum LiveStaging {
    public static func deviceID() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        gethostname(&buffer, buffer.count - 1)
        let host = String(cString: buffer)
        return "live-" + String(SHA256Digest.hex(Data(host.utf8)).prefix(12))
    }

    /// Python-style `datetime.isoformat()` for UTC, e.g. 2026-10-25T21:30:00.123456+00:00.
    public static func isoTimestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        return formatter.string(from: date) + "+00:00"
    }

    static func atomicWrite(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(getpid()).\(UUID().uuidString.prefix(8)).partial")
        try data.write(to: temp)
        if rename(temp.path, url.path) != 0 {
            try? FileManager.default.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    public static func writeJSON(_ value: JSONValue, to url: URL) throws {
        try atomicWrite(value.prettyJSONData + Data("\n".utf8), to: url)
    }

    /// Turn the raw PCM into incoming/<device>/<id>.wav + manifest (the contract the upload step reads).
    /// The manifest is written last: it is what makes the file visible to sync. Returns the recording info.
    @discardableResult
    public static func stageRecording(root: URL, sessionID: String, pcmURL: URL, startedAt: String, keepAudio: Bool = true, now: Date = Date()) throws -> JSONValue? {
        let fm = FileManager.default
        guard keepAudio, fm.fileExists(atPath: pcmURL.path),
              let size = (try? fm.attributesOfItem(atPath: pcmURL.path)[.size] as? NSNumber)?.intValue,
              size >= LiveAudio.rate * 2 else { return nil }
        let device = deviceID()
        let folder = root.appendingPathComponent("incoming").appendingPathComponent(device)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "\(sessionID).wav"
        let temp = folder.appendingPathComponent(".\(name).partial")
        fm.createFile(atPath: temp.path, contents: nil)
        let output = try FileHandle(forWritingTo: temp)
        let input = try FileHandle(forReadingFrom: pcmURL)
        defer { try? output.close(); try? input.close() }
        var digest = SHA256Digest()
        let header = LiveWAV.header(dataBytes: size)
        try output.write(contentsOf: header)
        digest.update(header)
        var copied = 0
        while copied < size, let chunk = try input.read(upToCount: min(1 << 20, size - copied)), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
            digest.update(chunk)
            copied += chunk.count
        }
        guard copied == size else { try? fm.removeItem(at: temp); return nil }
        try output.synchronize()
        let wavSize = header.count + size
        guard rename(temp.path, folder.appendingPathComponent(name).path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let objectKey = "recordings/incoming/\(device)/\(name)"
        let recording: JSONValue = [
            "id": .string(sessionID), "filename": .string(name), "size": JSONValue(wavSize), "sha256": .string(digest.finalize()),
            "signature": .null, "created_at": .string(startedAt), "object_key": .string(objectKey),
            "imported_at": .string(isoTimestamp(now))
        ]
        let manifest: JSONValue = [
            "schema_version": 1,
            "device": ["serial_number": .string(device), "model": "call-memory-live", "firmware": "1"],
            "recording": recording
        ]
        try writeJSON(manifest, to: folder.appendingPathComponent("\(name).manifest.json"))
        try? fm.removeItem(at: pcmURL)
        return recording
    }

    /// Stage audio left behind by a crashed call. Returns how many were recovered.
    @discardableResult
    public static func recoverPartials(root: URL, liveDirectory: URL? = nil) -> Int {
        let live = liveDirectory ?? root.appendingPathComponent("live")
        let sessions = (try? FileManager.default.contentsOfDirectory(at: live, includingPropertiesForKeys: nil)) ?? []
        var count = 0
        for directory in sessions.sorted(by: { $0.path < $1.path }) {
            let meta = directory.appendingPathComponent("session.json")
            let pcm = directory.appendingPathComponent("audio.pcm")
            guard FileManager.default.fileExists(atPath: pcm.path),
                  let data = try? Data(contentsOf: meta), let json = JSONValue.parse(data),
                  let id = json["id"]?.stringValue, let started = json["started_at"]?.stringValue else { continue }
            if (try? stageRecording(root: root, sessionID: id, pcmURL: pcm, startedAt: started)) ?? nil != nil { count += 1 }
        }
        return count
    }
}
