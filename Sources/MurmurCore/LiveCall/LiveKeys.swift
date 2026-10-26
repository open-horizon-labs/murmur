import Foundation

public struct MissingKey: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

/// Credential lookup. Settings name an environment variable or a command; they never hold the secret.
public enum LiveKeys {
    public static func resolve(keyEnv: String, keyCommand: [String], env: [String: String]? = nil) throws -> String {
        let env = env ?? ProcessInfo.processInfo.environment
        if !keyEnv.isEmpty, let value = env[keyEnv], !value.isEmpty {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !keyCommand.isEmpty {
            guard let output = run(keyCommand, timeout: 15) else {
                throw MissingKey(message: "key command failed (CalledProcessError)")
            }
            if !output.isEmpty { return output }
        }
        throw MissingKey(message: "no key: set \(keyEnv.isEmpty ? "key_env" : keyEnv) or key_command")
    }

    /// stdout of a successful command, trimmed; nil when it could not run, failed, or timed out.
    static func run(_ argv: [String], timeout: TimeInterval) -> String? {
        guard let program = argv.first, let executable = ProcessPCMSource.find(program) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(argv.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let collector = DataCollector()
        let reader = Thread { collector.set(pipe.fileHandleForReading.readDataToEndOfFile()) }
        reader.start()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); return nil }
        let finished = Date().addingTimeInterval(2)
        while !collector.isSet && Date() < finished { Thread.sleep(forTimeInterval: 0.01) }
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: collector.value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class DataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var done = false
    func set(_ value: Data) { lock.withLock { data = value; done = true } }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return done }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}
