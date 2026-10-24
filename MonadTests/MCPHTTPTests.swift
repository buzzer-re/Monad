//
//  MCPHTTPTests.swift — the MCP endpoint agents in a VM reach (agents
//  phase): HTTP parsed strictly from bytes, the token and Origin checks,
//  and the server on a real unix socket with keep-alive and its bounds.
//

import XCTest
@testable import Monad

final class MCPHTTPTests: XCTestCase {
    private let token = String(repeating: "ab", count: 32)

    private func request(_ body: String, headers: String? = nil, method: String = "POST", path: String = "/mcp") -> Data {
        let h = headers ?? "Authorization: Bearer \(token)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n"
        return Data("\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1:7766\r\n\(h)\r\n\(body)".utf8)
    }

    func testRequestsAreParsedStrictly() {
        guard case .request(let r, let consumed) = HTTPRequest.parse(request("{}") + Data("GET".utf8)) else {
            return XCTFail("a request")
        }
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/mcp")
        XCTAssertEqual(r.headers["content-length"], "2")
        XCTAssertEqual(r.body, Data("{}".utf8))
        XCTAssertEqual(consumed, request("{}").count, "the next request stays in the buffer")
        XCTAssertEqual(HTTPRequest.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 5\r\n\r\n{}".utf8)), .incomplete)
        XCTAssertEqual(HTTPRequest.parse(Data("POST /mcp HTTP/1.1\r\n".utf8)), .incomplete)
        let refused: [(String, Int)] = [
            ("POST /mcp HTTP/1.1\r\n\r\n", 411),
            ("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n", 501),
            ("POST /mcp HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n", 413),
            ("POST /mcp HTTP/1.1\r\nContent-Length: -1\r\n\r\n", 400),
            ("POST /mcp HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n", 400),
            ("POST /mcp HTTP/1.1\r\nBad Header: x\r\n\r\n", 400),
            ("post /mcp HTTP/1.1\r\n\r\n", 400),
            ("POST mcp HTTP/1.1\r\n\r\n", 400),
            ("POST /mcp HTTP/2\r\n\r\n", 400),
            ("POST /mcp HTTP/1.1\r\nX: caf\u{E9}\r\n\r\n", 400),
        ]
        for (text, status) in refused {
            guard case .refused(let s, _) = HTTPRequest.parse(Data(text.utf8)) else { XCTFail(text); continue }
            XCTAssertEqual(s, status, text)
        }
        let huge = Data(("POST /mcp HTTP/1.1\r\nX: " + String(repeating: "a", count: 9000)).utf8)
        guard case .refused(431, _) = HTTPRequest.parse(huge) else { return XCTFail("headers past 8 KB") }
    }

    func testTheEndpointChecksBeforeAnswering() async {
        func answer(_ data: Data) async -> HTTPResponse {
            guard case .request(let r, _) = HTTPRequest.parse(data) else { return HTTPResponse(status: 0) }
            return await MCPEndpoint.answer(r, token: token) { body in
                body == Data("note".utf8) ? nil : Data("{\"ok\":true}".utf8)
            }
        }
        var r = await answer(request("{}"))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.body, Data("{\"ok\":true}".utf8))
        r = await answer(request("note"))
        XCTAssertEqual(r.status, 202, "a notification")
        r = await answer(request("{}", headers: "Authorization: Bearer \(String(repeating: "cd", count: 32))\r\nContent-Length: 2\r\n"))
        XCTAssertEqual(r.status, 401)
        r = await answer(request("{}", headers: "Content-Length: 2\r\n"))
        XCTAssertEqual(r.status, 401)
        r = await answer(request("{}", headers: "Authorization: Bearer \(token)\r\nOrigin: http://evil.example\r\nContent-Length: 2\r\n"))
        XCTAssertEqual(r.status, 403, "a web page in the guest")
        r = await answer(request("", headers: "Authorization: Bearer \(token)\r\n", method: "GET"))
        XCTAssertEqual(r.status, 405)
        r = await answer(request("{}", path: "/other"))
        XCTAssertEqual(r.status, 404)
        XCTAssertFalse(MCPEndpoint.same("", ""), "an empty token never matches")
        let bytes = String(decoding: HTTPResponse(status: 401).bytes, as: UTF8.self)
        XCTAssertTrue(bytes.hasPrefix("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nWWW-Authenticate: Bearer\r\n"), bytes)
    }

    /// The server: answers on a kept-alive connection, a bad request closes it.
    func testTheServerAnswersOnItsSocket() throws {
        var template = Array("/tmp/mh-XXXXXX".utf8CString)
        let dir = String(cString: try XCTUnwrap(template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress) }))
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let socket = URL(fileURLWithPath: dir + "/mcp.sock")
        let server = MCPHTTPServer(socket: socket, token: token) { body in Data("echo:".utf8) + body }
        try server.start()
        defer { server.stop() }
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: socket.path))[.posixPermissions] as? Int, 0o600)
        let c = try UnixClient(socket.path)
        c.send(request("{\"a\":1}") + request("{\"b\":2}"))
        let two = c.read(until: { $0.components(separatedBy: "HTTP/1.1 200 OK").count == 3 && $0.hasSuffix("{\"b\":2}") })
        XCTAssertTrue(two.contains("echo:{\"a\":1}"), two)
        XCTAssertTrue(two.contains("echo:{\"b\":2}"), "kept alive: \(two)")
        c.send(Data("GARBAGE\r\n\r\n".utf8))
        let bad = c.read(until: { _ in false }, timeout: 2)
        XCTAssertTrue(bad.contains("HTTP/1.1 400"), bad)
        XCTAssertTrue(c.closed)
        let tokenFile = URL(fileURLWithPath: dir + "/mcp-token")
        let t = try MCPHTTPServer.token(at: tokenFile)
        XCTAssertEqual(t.count, 64)
        XCTAssertEqual(try MCPHTTPServer.token(at: tokenFile), t, "made once")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: tokenFile.path))[.posixPermissions] as? Int, 0o600)
    }
}
