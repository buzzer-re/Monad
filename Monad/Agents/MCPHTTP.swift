//
//  MCPHTTP.swift — Monad's MCP endpoint for agents in a VM (agents phase):
//  the Streamable HTTP subset Claude Code and Codex speak, on a private
//  unix socket in the VM's folder (0600) that the VM reaches at
//  127.0.0.1:<port> through a remote forward on its ssh master.
//
//  Only this: POST /mcp with a Content-Length body (no chunked encoding),
//  headers up to 8 KB, a body up to 1 MB, `Authorization: Bearer <the VM's
//  token>`, no Origin header (a browser in the guest has no business here);
//  the answer is application/json, or 202 for a notification. GET (the
//  optional event stream) is 405. Connections are kept alive, at most 8 at
//  once, closed when idle.
//

import Foundation
import Security

/// One HTTP request, parsed strictly from bytes.
struct HTTPRequest: Equatable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    static let maxHeaderBytes = 8 << 10
    static let maxBodyBytes = MCP.maxMessageBytes

    enum Parse: Equatable {
        /// Not all of it yet.
        case incomplete
        /// A request, and how many bytes it took.
        case request(HTTPRequest, consumed: Int)
        /// Refused with this status and reason (the connection then closes).
        case refused(Int, String)
    }

    /// The first request in `data`.
    static func parse(_ data: Data) -> Parse {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHeaderBytes ? .refused(431, "Headers too large") : .incomplete
        }
        guard end.lowerBound <= maxHeaderBytes else { return .refused(431, "Headers too large") }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8),
              head.unicodeScalars.allSatisfy({ $0.value == 9 || $0.value == 10 || $0.value == 13 || (0x20..<0x7F).contains($0.value) })
        else { return .refused(400, "Bad request") }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard start.count == 3, start[2] == "HTTP/1.1" || start[2] == "HTTP/1.0",
              start[0].allSatisfy({ $0.isUppercase }), !start[0].isEmpty, start[1].hasPrefix("/") else {
            return .refused(400, "Bad request")
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                  !line[..<colon].contains(where: { $0 == " " || $0 == "\t" }) else { return .refused(400, "Bad header") }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard headers[name] == nil else { return .refused(400, "Repeated header \(name)") }
            headers[name] = value
        }
        if headers["transfer-encoding"] != nil { return .refused(501, "Transfer-Encoding is not supported") }
        var length = 0
        if let text = headers["content-length"] {
            guard let n = Int(text), n >= 0, text.allSatisfy(\.isNumber) else { return .refused(400, "Bad Content-Length") }
            guard n <= maxBodyBytes else { return .refused(413, "Body too large") }
            length = n
        } else if start[0] == "POST" {
            return .refused(411, "Content-Length required")
        }
        let bodyStart = end.upperBound
        guard data.distance(from: bodyStart, to: data.endIndex) >= length else { return .incomplete }
        let body = data[bodyStart..<data.index(bodyStart, offsetBy: length)]
        return .request(HTTPRequest(method: String(start[0]), path: String(start[1]), headers: headers, body: Data(body)),
                        consumed: data.distance(from: data.startIndex, to: bodyStart) + length)
    }

    var keepAlive: Bool { headers["connection"]?.lowercased() != "close" }
}

/// An answer.
struct HTTPResponse: Equatable {
    var status: Int
    var body: Data = Data()
    var contentType = "application/json"
    var close = false

    static func reason(_ status: Int) -> String {
        [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
         405: "Method Not Allowed", 411: "Length Required", 413: "Payload Too Large", 431: "Request Header Fields Too Large",
         501: "Not Implemented", 503: "Service Unavailable"][status] ?? "Error"
    }

    var bytes: Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\nContent-Length: \(body.count)\r\n"
        if !body.isEmpty { head += "Content-Type: \(contentType)\r\n" }
        if status == 405 { head += "Allow: POST\r\n" }
        if status == 401 { head += "WWW-Authenticate: Bearer\r\n" }
        head += close ? "Connection: close\r\n\r\n" : "\r\n"
        return Data(head.utf8) + body
    }

    static func text(_ status: Int, _ message: String, close: Bool = false) -> HTTPResponse {
        HTTPResponse(status: status, body: Data((message + "\n").utf8), contentType: "text/plain; charset=utf-8", close: close)
    }
}

/// What the endpoint does with a request: the checks, then the MCP engine.
enum MCPEndpoint {
    static func answer(_ r: HTTPRequest, token: String, handle: (Data) async -> Data?) async -> HTTPResponse {
        guard r.path == "/mcp" || r.path.hasPrefix("/mcp?") else { return .text(404, "Not here: POST /mcp") }
        guard r.headers["origin"] == nil else { return .text(403, "Requests from a web page are refused.") }
        guard let auth = r.headers["authorization"], auth.hasPrefix("Bearer "),
              Self.same(String(auth.dropFirst(7)), token) else {
            return .text(401, "The VM's token is in ~/.monad/mcp.env (MONAD_MCP_TOKEN).")
        }
        guard r.method == "POST" else { return HTTPResponse(status: 405) }
        guard let reply = await handle(r.body) else { return HTTPResponse(status: 202) }
        return HTTPResponse(status: 200, body: reply)
    }

    /// Compares without stopping at the first difference.
    static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count, !y.isEmpty else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}

/// What VMInstance needs of the endpoint (fakes in tests).
protocol MCPEndpointServing: AnyObject {
    func start() throws
    func stop()
}

/// Where the endpoints send what agents in VMs say: MonadHost's MCP server
/// (HostService sets it).
@MainActor
enum MCPRouter {
    static var handler: ((String, Data) async -> Data?)?

    static func route(_ vm: String, _ data: Data) async -> Data? {
        guard let handler else { return MCPServer.error(nil, .internalError, "Monad's MCP server is not running.") }
        return await handler(vm, data)
    }
}

/// The endpoint's socket: connections, requests, answers.
final class MCPHTTPServer: MCPEndpointServing, @unchecked Sendable {
    private let socket: URL
    private let token: String
    private let handle: @Sendable (Data) async -> Data?
    private let queue = DispatchQueue(label: "dev.monad.mcp.http")
    private var listener: Int32 = -1
    private var accepting: DispatchSourceRead?
    private var connections: [Int32: DispatchSourceRead] = [:]
    static let maxConnections = 8
    static let idleSeconds: TimeInterval = 300

    init(socket: URL, token: String, handle: @escaping @Sendable (Data) async -> Data?) {
        self.socket = socket
        self.token = token
        self.handle = handle
    }

    deinit { stop() }

    func start() throws {
        let fd = try BridgeServer.listen(at: socket.path, what: "Monad's MCP socket")
        queue.sync {
            listener = fd
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptAll() }
            source.resume()
            accepting = source
        }
    }

    func stop() {
        queue.sync {
            accepting?.cancel()
            accepting = nil
            if listener >= 0 {
                close(listener)
                listener = -1
                unlink(socket.path)
            }
            for (_, s) in connections { s.cancel() }
            connections = [:]
        }
    }

    private func acceptAll() {
        while listener >= 0 {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            guard connections.count < Self.maxConnections else {
                write(fd, HTTPResponse.text(503, "Too many connections.", close: true).bytes)
                close(fd)
                continue
            }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            serve(fd)
        }
    }

    private func serve(_ fd: Int32) {
        var buffer = Data()
        var busy = false
        var lastActivity = Date()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        connections[fd] = source
        source.setCancelHandler { close(fd) }
        let idle = DispatchSource.makeTimerSource(queue: queue)
        idle.schedule(deadline: .now() + 30, repeating: 30)
        idle.setEventHandler { [weak self] in
            if !busy, Date().timeIntervalSince(lastActivity) > Self.idleSeconds { self?.drop(fd); idle.cancel() }
            if source.isCancelled { idle.cancel() }
        }
        idle.resume()
        func next() {
            guard !busy, !source.isCancelled else { return }
            switch HTTPRequest.parse(buffer) {
            case .incomplete:
                return
            case .refused(let status, let why):
                write(fd, HTTPResponse.text(status, why, close: true).bytes)
                drop(fd)
            case .request(let request, let consumed):
                buffer.removeFirst(consumed)
                busy = true
                let token = self.token, handle = self.handle
                Task {
                    var response = await MCPEndpoint.answer(request, token: token, handle: handle)
                    response.close = response.close || !request.keepAlive
                    self.queue.async {
                        busy = false
                        lastActivity = Date()
                        guard !source.isCancelled else { return }
                        self.write(fd, response.bytes)
                        if response.close { self.drop(fd) } else { next() }
                    }
                }
            }
        }
        source.setEventHandler { [weak self] in
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &chunk, chunk.count)
            if n < 0, errno == EAGAIN || errno == EINTR { return }
            guard n > 0 else { self?.drop(fd); return }
            lastActivity = Date()
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > HTTPRequest.maxHeaderBytes + HTTPRequest.maxBodyBytes + 1024 {
                self?.write(fd, HTTPResponse.text(413, "Too large", close: true).bytes)
                self?.drop(fd)
                return
            }
            next()
        }
        source.resume()
    }

    private func drop(_ fd: Int32) {
        connections.removeValue(forKey: fd)?.cancel()
    }

    /// Blocking write of a whole answer (the socket is the VM's own).
    private func write(_ fd: Int32, _ data: Data) {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        var limit = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { return }
                off += n
            }
        }
        _ = fcntl(fd, F_SETFL, flags)
    }

    /// The VM's token: 32 random bytes in hex, made once, kept 0600 beside
    /// the socket.
    static func token(at url: URL) throws -> String {
        if let t = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           t.count == 64, t.allSatisfy(\.isHexDigit) {
            return t
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw MonadError("Cannot make a token.")
        }
        let t = bytes.map { String(format: "%02x", $0) }.joined()
        try Data(t.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return t
    }
}
