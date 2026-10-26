import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import MurmurCore
import XCTest
@testable import MurmurLiveServer

/// Real loopback sockets, fake call: exercises the same routes as call-memory's web.py.
final class LiveServerTests: XCTestCase {
    struct Reply { let status: Int; let body: Data; var text: String { String(decoding: body, as: UTF8.self) }; var json: JSONValue? { JSONValue.parse(body) } }

    func request(_ server: LiveServer, _ method: String, _ path: String, token: Bool = true, host: String? = nil, body: String? = nil) async throws -> Reply {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)\(path)")!)
        request.httpMethod = method
        if token { request.setValue(server.token, forHTTPHeaderField: "X-Call-Memory-Token") }
        if let host { request.setValue(host, forHTTPHeaderField: "Host") }
        if let body { request.httpBody = Data(body.utf8); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: request)
        return Reply(status: (response as! HTTPURLResponse).statusCode, body: data)
    }

    func makeServer(session: @escaping LiveServer.MakeSession = { DemoSession(speed: 60) }) throws -> LiveServer {
        try LiveServer(makeSession: session, makeDemo: { DemoSession(speed: 60) },
                       readiness: { ["rows": [["id": "asr", "label": "Transcription", "state": "ok", "detail": "ready", "fix": ""]], "can_start": true] },
                       page: "<html>token=__TOKEN__</html>").start()
    }

    func testPageNeedsTheTokenAndEmbedsIt() async throws {
        let server = try makeServer()
        let denied = try await request(server, "GET", "/", token: false)
        XCTAssertEqual(denied.status, 403)
        let wrong = try await request(server, "GET", "/?t=nope", token: false)
        XCTAssertEqual(wrong.status, 403)
        let page = try await request(server, "GET", "/?t=\(server.token)", token: false)
        XCTAssertEqual(page.status, 200)
        XCTAssertEqual(page.text, "<html>token=\(server.token)</html>")
        XCTAssertTrue(server.url.hasSuffix("/?t=\(server.token)"))
        await server.stop()
    }

    func testApiNeedsTokenAndAnExactLoopbackHost() async throws {
        let server = try makeServer()
        let noToken = try await request(server, "GET", "/api/state", token: false)
        XCTAssertEqual(noToken.status, 404)    // same as web.py: unauthenticated API routes fall through to 404
        let post = try await request(server, "POST", "/api/start", token: false)
        XCTAssertEqual(post.status, 403)
        #if os(Linux)   // Darwin's URLSession ignores a custom Host header
        let rebinding = try await request(server, "GET", "/api/readiness", host: "evil.example:\(server.port)")
        XCTAssertEqual(rebinding.status, 403)
        #endif
        let ready = try await request(server, "GET", "/api/readiness")
        XCTAssertEqual(ready.json?["can_start"]?.boolValue, true)
        let idle = try await request(server, "GET", "/api/state")
        XCTAssertEqual(idle.json?["status"]?.stringValue, "idle")
        let unknown = try await request(server, "GET", "/api/nothing")
        XCTAssertEqual(unknown.status, 404)
        await server.stop()
    }

    func testStartDemoStateRecapStopAndSingleCall() async throws {
        let server = try makeServer()
        let noCall = try await request(server, "POST", "/api/recap", body: "{}")
        XCTAssertEqual(noCall.json?["ok"]?.boolValue, false)
        XCTAssertEqual(noCall.json?["message"]?.stringValue, "No call yet.")
        let stopNothing = try await request(server, "POST", "/api/stop")
        XCTAssertEqual(stopNothing.status, 404)
        let started = try await request(server, "POST", "/api/demo")
        XCTAssertEqual(started.json?["ok"]?.boolValue, true)
        let again = try await request(server, "POST", "/api/start")
        XCTAssertEqual(again.json?["message"]?.stringValue, "A call is already running.")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let state = try await request(server, "GET", "/api/state")
        XCTAssertEqual(state.json?["sample"]?.boolValue, true)
        XCTAssertGreaterThan(state.json?["entries"]?.arrayValue?.count ?? 0, 0)
        let recap = try await request(server, "POST", "/api/recap", body: #"{"minutes": 10}"#)
        XCTAssertEqual(recap.json?["ok"]?.boolValue, true)
        XCTAssertEqual(recap.json?["recap"]?["minutes"]?.intValue, 10)
        let bad = try await request(server, "POST", "/api/recap", body: #"{"minutes": "x"}"#)
        XCTAssertEqual(bad.status, 400)
        let stopped = try await request(server, "POST", "/api/stop")
        XCTAssertEqual(stopped.json?["ok"]?.boolValue, true)
        await server.stop()
    }

    func testStartFailureIsReportedAndLeavesNoCall() async throws {
        struct Broken: LocalizedError { var errorDescription: String? { "no key" } }
        let server = try makeServer(session: { throw Broken() })
        let result = try await request(server, "POST", "/api/start")
        XCTAssertEqual(result.json?["ok"]?.boolValue, false)
        XCTAssertEqual(result.json?["message"]?.stringValue, "Could not start: no key")
        let state = try await request(server, "GET", "/api/state")
        XCTAssertEqual(state.json?["status"]?.stringValue, "idle")
        await server.stop()
    }

    func testEventStreamDeliversSessionEvents() async throws {
        let server = try makeServer()
        let noCall = try await request(server, "GET", "/api/events?t=\(server.token)")
        XCTAssertEqual(noCall.status, 409)
        _ = try await request(server, "POST", "/api/demo")
        let collected = EventCollector()
        let task = Task.detached {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/api/events?t=\(server.token)")!)
            request.timeoutInterval = 20
            let delegate = StreamDelegate(collected)
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            session.dataTask(with: request).resume()
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            session.invalidateAndCancel()
        }
        await task.value
        XCTAssertTrue(collected.text.contains("retry: 1000"))
        XCTAssertTrue(collected.text.contains("data: {"))
        XCTAssertTrue(collected.text.contains("\"type\":\"entry\"") || collected.text.contains("\"type\":\"partial\""))
        await server.stop()
    }

    func testBundledPageIsTheLivePage() {
        let page = LiveServer.loadPage()
        XCTAssertTrue(page.contains("__TOKEN__"))
        XCTAssertTrue(page.contains("/api/events"))
        XCTAssertTrue(page.contains("/api/recap"))
    }
}

final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    func append(_ text: String) { lock.withLock { buffer += text } }
    var text: String { lock.withLock { buffer } }
}

final class StreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let collector: EventCollector
    init(_ collector: EventCollector) { self.collector = collector }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        collector.append(String(decoding: data, as: UTF8.self))
    }
}
