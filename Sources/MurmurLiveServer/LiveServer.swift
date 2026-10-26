import Foundation
import MurmurCore

/// Run an async operation from a synchronous connection thread.
private final class ResultBox<T: Sendable>: @unchecked Sendable { var value: T? }

func runBlocking<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task {
        box.value = await operation()
        done.signal()
    }
    done.wait()
    return box.value!
}

/// Local page for a live call: transcript and Context over server-sent events. Loopback and token only.
/// Same HTTP/SSE API as call-memory's `src/call_memory/live/web.py`:
/// `/`, `/api/state`, `/api/events`, `/api/start`, `/api/stop`, `/api/recap`, `/api/demo`, `/api/readiness`.
public final class LiveServer: @unchecked Sendable {
    public typealias MakeSession = @Sendable () throws -> any LiveCallControlling
    public typealias Readiness = @Sendable () async -> JSONValue

    public let token: String
    private let makeSession: MakeSession
    private let makeDemo: MakeSession
    private let readiness: Readiness
    private let page: String
    private let lock = NSLock()
    private var session: (any LiveCallControlling)?
    private var http: HTTPServer!

    public var host: String { http.host }
    public var port: Int { http.port }
    public var url: String { "http://\(host):\(port)/?t=\(token)" }
    public var currentSession: (any LiveCallControlling)? { lock.withLock { session } }

    public static func loadPage() -> String {
        guard let url = Bundle.module.url(forResource: "page", withExtension: "html"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "<!doctype html><title>Call Memory</title><p>The live page is missing from this build."
        }
        return text
    }

    public init(
        makeSession: @escaping MakeSession,
        makeDemo: @escaping MakeSession = { DemoSession() },
        readiness: @escaping Readiness = { ["rows": [], "can_start": true] },
        host: String = "127.0.0.1",
        port: Int = 0,
        page: String? = nil
    ) throws {
        self.makeSession = makeSession
        self.makeDemo = makeDemo
        self.readiness = readiness
        self.page = page ?? Self.loadPage()
        var bytes = [UInt8](repeating: 0, count: 24)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        token = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        http = try HTTPServer(host: host, port: port) { [unowned self] request, responder in handle(request, responder) }
    }

    @discardableResult
    public func start() -> LiveServer { http.start(); return self }

    public func stop() async {
        if let session = currentSession { await session.stop() }
        http.stop()
    }

    // MARK: actions

    func recap(minutes: Int) -> JSONValue {
        guard let session = currentSession else { return ["ok": false, "message": "No call yet."] }
        let clamped = max(1, min(minutes, 60))
        return runBlocking {
            do { return ["ok": true, "recap": try await session.recap(minutes: clamped)] as JSONValue }
            catch { return ["ok": false, "message": .string("Could not summarize: \(error.localizedDescription)")] as JSONValue }
        }
    }

    func action(_ path: String) -> JSONValue? {
        lock.lock(); defer { lock.unlock() }
        switch path {
        case "/api/start", "/api/demo":
            if let session, ["listening", "stopping"].contains(session.status) {
                return ["ok": false, "message": "A call is already running."]
            }
            do {
                let next = try (path == "/api/demo" ? makeDemo() : makeSession())
                session = next
                try next.start()
            } catch {
                session = nil
                return ["ok": false, "message": .string("Could not start: \(error.localizedDescription)")]
            }
            return ["ok": true]
        case "/api/stop":
            guard let session else { return nil }
            Task { await session.stop() }
            return ["ok": true]
        default:
            return nil
        }
    }

    // MARK: HTTP

    private func hostOK(_ request: HTTPRequest) -> Bool {
        let value = request.headers["host"]
        return value == "127.0.0.1:\(port)" || value == "localhost:\(port)"
    }

    private func tokenOK(_ value: String?) -> Bool {
        let a = Array((value ?? "").utf8), b = Array(token.utf8)
        var difference = a.count ^ b.count
        for index in 0..<min(a.count, b.count) { difference |= Int(a[index] ^ b[index]) }
        return difference == 0
    }

    private static let securityHeaders: [(String, String)] = [
        ("Cache-Control", "no-store"),
        ("X-Content-Type-Options", "nosniff"),
        ("Content-Security-Policy", "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
            + "connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
    ]

    private func send(_ responder: HTTPResponder, _ status: Int, json value: JSONValue) {
        responder.send(status: status, headers: [("Content-Type", "application/json; charset=utf-8")] + Self.securityHeaders,
                       body: Data(value.jsonText.utf8))
    }

    private func send(_ responder: HTTPResponder, _ status: Int, text: String, type: String) {
        responder.send(status: status, headers: [("Content-Type", type)] + Self.securityHeaders, body: Data(text.utf8))
    }

    private func handle(_ request: HTTPRequest, _ responder: HTTPResponder) {
        switch request.method {
        case "GET": handleGET(request, responder)
        case "POST": handlePOST(request, responder)
        default: send(responder, 404, json: ["ok": false])
        }
    }

    private func handleGET(_ request: HTTPRequest, _ responder: HTTPResponder) {
        guard hostOK(request) else { return send(responder, 403, json: ["ok": false]) }
        let headerToken = request.headers["x-call-memory-token"]
        switch request.path {
        case "/":
            guard tokenOK(request.query["t"]) else {
                return send(responder, 403, text: "Open this page from the Call Memory menu.", type: "text/plain")
            }
            send(responder, 200, text: page.replacingOccurrences(of: "__TOKEN__", with: token), type: "text/html; charset=utf-8")
        case "/api/state" where tokenOK(headerToken):
            send(responder, 200, json: currentSession?.state() ?? ["status": "idle", "entries": []])
        case "/api/readiness" where tokenOK(headerToken):
            send(responder, 200, json: runBlocking { await self.readiness() })
        case "/api/events" where tokenOK(request.query["t"]):
            events(responder)
        default:
            send(responder, 404, json: ["ok": false])
        }
    }

    private func events(_ responder: HTTPResponder) {
        guard let session = currentSession else { return send(responder, 409, json: ["ok": false, "message": "no call"]) }
        let queue = session.subscribe()
        defer { session.unsubscribe(queue) }
        guard responder.beginStream(headers: [("Content-Type", "text/event-stream"), ("Cache-Control", "no-store")]),
              responder.write(Data("retry: 1000\n\n".utf8)) else { return }
        while true {
            let payload = queue.get(timeout: 15).map { "data: \($0.jsonText)\n\n" } ?? ": keepalive\n\n"
            if !responder.write(Data(payload.utf8)) { return }
        }
    }

    private func handlePOST(_ request: HTTPRequest, _ responder: HTTPResponder) {
        guard hostOK(request), tokenOK(request.headers["x-call-memory-token"]) else {
            return send(responder, 403, json: ["ok": false])
        }
        if request.path == "/api/recap" {
            let body = request.body.isEmpty ? JSONValue.object([:]) : (JSONValue.parse(request.body) ?? .null)
            guard body.objectValue != nil else { return send(responder, 400, json: ["ok": false]) }
            let minutes: Int
            switch body["minutes"] {
            case nil: minutes = 5
            case .number(let value)?: minutes = Int(value)
            case .string(let text)?: guard let parsed = Int(text) else { return send(responder, 400, json: ["ok": false]) }; minutes = parsed
            default: return send(responder, 400, json: ["ok": false])
            }
            return send(responder, 200, json: recap(minutes: minutes))
        }
        if let result = action(request.path) { send(responder, 200, json: result) } else { send(responder, 404, json: ["ok": false]) }
    }
}
