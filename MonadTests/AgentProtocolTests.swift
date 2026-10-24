//
//  AgentProtocolTests.swift — host-side parsing of monad-agent output.
//  Everything here is guest-controlled input: strict, bounded, no surprises.
//

import XCTest
@testable import Monad

final class AgentProtocolTests: XCTestCase {
    private func p(_ line: String) -> AgentMessage? { AgentMessage.parse(line) }

    /// How the debug log shows agent messages; pings (every 10 s) are left out.
    func testDebugText() {
        let p = ListeningPort(address: "127.0.0.53", port: 53)
        XCTAssertEqual(AgentMessage.hello(version: 1).debugText, "hello, protocol 1")
        XCTAssertEqual(AgentMessage.mode(.events).debugText, "watching ports through kernel events")
        XCTAssertEqual(AgentMessage.mode(.polling).debugText, "watching ports by checking every second")
        XCTAssertEqual(AgentMessage.opened(p).debugText, "port opened 127.0.0.53:53")
        XCTAssertEqual(AgentMessage.closed(p).debugText, "port closed 127.0.0.53:53")
        XCTAssertEqual(AgentMessage.port(p).debugText, "port listening 127.0.0.53:53")
        XCTAssertEqual(AgentMessage.error("x").debugText, "error: x")
        XCTAssertNil(AgentMessage.ping.debugText)
    }

    func testValidMessages() {
        XCTAssertEqual(p("hello monad-agent 1"), .hello(version: 1))
        XCTAssertEqual(p("port tcp 0.0.0.0 8080"), .port(ListeningPort(address: "0.0.0.0", port: 8080)))
        XCTAssertEqual(p("port+ tcp 127.0.0.1 5432"), .opened(ListeningPort(address: "127.0.0.1", port: 5432)))
        XCTAssertEqual(p("port- tcp :: 3000"), .closed(ListeningPort(address: "::", port: 3000)))
        XCTAssertEqual(p("port+ tcp 2001:db8:0:0:0:0:0:1 8081"),
                       .opened(ListeningPort(address: "2001:db8:0:0:0:0:0:1", port: 8081)))
        XCTAssertEqual(p("end"), .end)
        XCTAssertEqual(p("ping"), .ping)
        XCTAssertEqual(p("error unknown-command"), .error("unknown-command"))
        XCTAssertEqual(p("mode events"), .mode(.events))
        XCTAssertEqual(p("mode polling"), .mode(.polling))
        XCTAssertEqual(p("prompt password"), .prompt)
        XCTAssertNil(p("prompt"))
        XCTAssertNil(p("prompt passwords"))
    }

    func testRejectsMalformedLines() {
        for bad in [
            "", " ", "hello", "hello monad-agent", "hello monad-agent x", "hello other 1",
            "port tcp 0.0.0.0", "port tcp 0.0.0.0 0", "port tcp 0.0.0.0 65536", "port tcp 0.0.0.0 -1",
            "port tcp 0.0.0.0 +80", "port tcp 0.0.0.0 08080", "port tcp 0.0.0.0 80 extra",
            "port udp 0.0.0.0 53", "port tcp localhost 80", "port tcp 999.0.0.1 80", "port tcp 0.0.0.0  80",
            "port* tcp 0.0.0.0 80", "PORT tcp 0.0.0.0 80", "end now", "ping pong",
            "error", "error Has Spaces", "error with\u{1B}[31mescape", "error " + String(repeating: "x", count: 65),
            "port tcp 0.0.0.0 80\u{0}", "héllo monad-agent 1", "mode", "mode turbo", "mode events now",
        ] {
            XCTAssertNil(p(bad), "accepted: \(bad.debugDescription)")
        }
        XCTAssertNil(p("port tcp " + String(repeating: "1", count: 600) + " 80"), "overlong line")
    }

    func testPortClassification() {
        XCTAssertTrue(ListeningPort(address: "127.0.0.1", port: 1).isLoopback)
        XCTAssertTrue(ListeningPort(address: "127.0.0.53", port: 53).isLoopback)
        XCTAssertTrue(ListeningPort(address: "::1", port: 1).isLoopback)
        XCTAssertFalse(ListeningPort(address: "0.0.0.0", port: 1).isLoopback)
        XCTAssertTrue(ListeningPort(address: "0.0.0.0", port: 1).isWildcard)
        XCTAssertTrue(ListeningPort(address: "::", port: 1).isWildcard)
        XCTAssertFalse(ListeningPort(address: "10.0.0.5", port: 1).isWildcard)
    }

    // MARK: Line reader

    func testReaderSplitsChunksIntoLines() {
        var r = AgentLineReader()
        XCTAssertEqual(r.feed(Data("hello monad".utf8)), [])
        XCTAssertEqual(r.feed(Data("-agent 1\nping\npo".utf8)), ["hello monad-agent 1", "ping"])
        XCTAssertEqual(r.feed(Data("rt+ tcp :: 3000\r\n".utf8)), ["port+ tcp :: 3000"])
    }

    func testReaderDropsOverlongLinesAndResynchronizes() {
        var r = AgentLineReader(maxLineLength: 64)
        XCTAssertEqual(r.feed(Data(repeating: 0x41, count: 1000)), [])
        XCTAssertLessThanOrEqual(r.bufferedBytes, 64, "memory stays bounded while no newline arrives")
        XCTAssertEqual(r.feed(Data("AAAA\nping\n".utf8)), ["ping"], "the overlong line is discarded as a whole")
        XCTAssertEqual(r.droppedLines, 1)
    }

    func testReaderRejectsInvalidUTF8Lines() {
        var r = AgentLineReader()
        XCTAssertEqual(r.feed(Data([0xFF, 0xFE, 0x0A]) + Data("ping\n".utf8)), ["ping"])
    }
}
