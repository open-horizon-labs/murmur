import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// One parsed HTTP/1.1 request.
public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let query: [String: String]
    public let headers: [String: String]   // lowercased names
    public let body: Data
}

/// A response writer handed to the handler. `sendSSE` keeps the connection open for server-sent events.
public final class HTTPResponder: @unchecked Sendable {
    fileprivate let descriptor: Int32
    public init(descriptor: Int32) { self.descriptor = descriptor }

    @discardableResult
    public func send(status: Int, headers: [(String, String)], body: Data) -> Bool {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return write(Data(head.utf8)) && write(body)
    }

    /// Begin a `text/event-stream` response; subsequent `write` calls send events.
    @discardableResult
    public func beginStream(headers: [(String, String)]) -> Bool {
        var head = "HTTP/1.1 200 OK\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Connection: close\r\n\r\n"
        return write(Data(head.utf8))
    }

    public func write(_ data: Data) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { raw -> Bool in
            while offset < data.count {
                #if os(Linux)
                let sent = Glibc.send(descriptor, raw.baseAddress! + offset, data.count - offset, Int32(MSG_NOSIGNAL))
                #else
                let sent = Darwin.send(descriptor, raw.baseAddress! + offset, data.count - offset, 0)
                #endif
                if sent < 0 { if errno == EINTR { continue }; return false }
                if sent == 0 { return false }
                offset += sent
            }
            return true
        }
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 409: "Conflict"
        default: "Status"
        }
    }
}

/// A small dependency-free HTTP/1.1 server on a loopback TCP socket. One thread per connection; no keep-alive.
/// It exists so the live-call UI works on Linux (no Network.framework) and macOS without a web framework.
public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest, HTTPResponder) -> Void

    public let host: String
    public private(set) var port: Int = 0
    private var listener: Int32 = -1
    private let lock = NSLock()
    private var stopped = false
    private let handler: Handler
    private static let maxHeader = 16 * 1024
    private static let maxBody = 64 * 1024

    public init(host: String = "127.0.0.1", port: Int = 0, handler: @escaping Handler) throws {
        self.host = host
        self.handler = handler
        signal(SIGPIPE, SIG_IGN)
        #if os(Linux)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw HTTPServerError.socket(errno) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { close(fd); throw HTTPServerError.address(host) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 64) == 0 else { let code = errno; close(fd); throw HTTPServerError.socket(code) }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        self.port = Int(UInt16(bigEndian: actual.sin_port))
        listener = fd
    }

    public func start() {
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    public func stop() {
        lock.lock(); stopped = true; lock.unlock()
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private func acceptLoop() {
        while !isStopped {
            var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, 200)
            if ready <= 0 { continue }
            let client = accept(listener, nil, nil)
            if client < 0 { continue }
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            #if !os(Linux)
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            #endif
            Thread.detachNewThread { [self] in serve(client) }
        }
        close(listener)
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        guard let request = Self.readRequest(client) else {
            HTTPResponder(descriptor: client).send(status: 400, headers: [("Content-Type", "text/plain")], body: Data("bad request".utf8))
            return
        }
        handler(request, HTTPResponder(descriptor: client))
    }

    private static func readRequest(_ fd: Int32) -> HTTPRequest? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let separator = Data("\r\n\r\n".utf8)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<count])
            headerEnd = buffer.range(of: separator)
            if headerEnd == nil && buffer.count > maxHeader { return nil }
        }
        guard let end = headerEnd, let head = String(data: buffer[..<end.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0, length <= maxBody else { return nil }
        var body = Data(buffer[end.upperBound...])
        while body.count < length {
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 { return nil }
            body.append(contentsOf: chunk[0..<count])
        }
        let target = String(parts[1])
        var path = target
        var query: [String: String] = [:]
        if let mark = target.firstIndex(of: "?") {
            path = String(target[..<mark])
            var components = URLComponents()
            components.query = String(target[target.index(after: mark)...])
            for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        }
        return HTTPRequest(method: String(parts[0]), path: path, query: query, headers: headers, body: Data(body.prefix(length)))
    }
}

public enum HTTPServerError: Error, LocalizedError {
    case socket(Int32)
    case address(String)

    public var errorDescription: String? {
        switch self {
        case .socket(let code): "could not open the local server socket (errno \(code))"
        case .address(let host): "invalid listen address \(host)"
        }
    }
}
