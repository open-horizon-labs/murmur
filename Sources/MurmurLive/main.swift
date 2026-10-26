import Foundation
import MurmurCore
import MurmurLiveServer

/// murmur-live: `serve` opens the live-call page on loopback; `run` prints the transcript and notes in a terminal.
/// Port of call-memory's scripts/live.py. Keys come from the environment (or key_command), never from settings.

func out(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }

func defaultRoot() -> URL {
    let env = ProcessInfo.processInfo.environment
    if let override = env["CALL_MEMORY_ROOT"], !override.isEmpty { return URL(fileURLWithPath: override, isDirectory: true) }
    let home = FileManager.default.homeDirectoryForCurrentUser
    #if os(Linux)
    let base = env["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) } ?? home.appendingPathComponent(".local/share")
    return base.appendingPathComponent("call-memory", isDirectory: true)
    #else
    return home.appendingPathComponent("Library/Application Support/Call Memory", isDirectory: true)
    #endif
}

struct Options {
    var mode = "serve"
    var root = defaultRoot()
    var openBrowser = true
    var port = 0
    var envFiles: [URL] = []
}

func parseOptions(_ arguments: [String]) -> Options? {
    var options = Options()
    var args = arguments.dropFirst()
    guard let mode = args.first, ["serve", "run"].contains(mode) else { return nil }
    options.mode = mode
    args = args.dropFirst()
    while let arg = args.first {
        args = args.dropFirst()
        switch arg {
        case "--no-browser": options.openBrowser = false
        case "--root": guard let value = args.first else { return nil }; options.root = URL(fileURLWithPath: value, isDirectory: true); args = args.dropFirst()
        case "--port": guard let value = args.first, let port = Int(value) else { return nil }; options.port = port; args = args.dropFirst()
        case "--env-file": guard let value = args.first else { return nil }; options.envFiles.append(URL(fileURLWithPath: value)); args = args.dropFirst()
        default: return nil
        }
    }
    return options
}

func openBrowser(_ url: String) {
    #if os(Linux)
    let program = "/usr/bin/xdg-open"
    #else
    let program = "/usr/bin/open"
    #endif
    guard FileManager.default.isExecutableFile(atPath: program) else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: program)
    process.arguments = [url]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
}

func readinessProvider(root: URL) -> LiveServer.Readiness {
    { await LiveReadiness.readiness(LiveSettings.load(root: root)) }
}

guard let options = parseOptions(CommandLine.arguments) else {
    FileHandle.standardError.write(Data("usage: murmur-live (serve|run) [--root DIR] [--env-file FILE]... [--port N] [--no-browser]\n".utf8))
    exit(2)
}

LiveConfig.loadEnvFiles(options.envFiles + [options.root.appendingPathComponent(".env")])
let root = options.root

if options.mode == "serve" {
    do {
        let server = try LiveServer(makeSession: { try LiveConfig.makeSession(root: root) }, readiness: readinessProvider(root: root), port: options.port).start()
        out(server.url)
        if options.openBrowser { openBrowser(server.url) }
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let sources = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                Task { await server.stop(); exit(0) }
            }
            source.resume()
            return source
        }
        withExtendedLifetime(sources) { dispatchMain() }
    } catch {
        FileHandle.standardError.write(Data("murmur-live: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
} else {
    do {
        let session = try LiveConfig.makeSession(root: root)
        let events = session.subscribe()
        try session.start()
        let stopRequested = DispatchSemaphore(value: 0)
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupt.setEventHandler { stopRequested.signal() }
        interrupt.resume()
        out("Listening. Ctrl-C to stop.")
        let printer = Thread {
            while true {
                guard let event = events.get(timeout: 0.5) else { continue }
                switch event["type"]?.stringValue {
                case "entry":
                    if let entry = event["entry"] { out("[\(entry["id"]?.intValue ?? 0)] \(entry["speaker"]?.stringValue ?? ""): \(entry["text"]?.stringValue ?? "")") }
                case "context":
                    let summary = event["context"]?["summary"]?.stringValue ?? ""
                    let error = event["error"]?.stringValue.map { "  (error: \($0))" } ?? ""
                    out("  notes: \(summary)\(error)")
                case "notice":
                    out("  ! \(event["text"]?.stringValue ?? "")")
                default: break
                }
                    }
        }
        printer.start()
        stopRequested.wait()
        let finished = DispatchSemaphore(value: 0)
        Task { await session.stop(); finished.signal() }
        finished.wait()
        out("Saved \(session.directory.path)")
        withExtendedLifetime(interrupt) {}
    } catch {
        FileHandle.standardError.write(Data("murmur-live: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
