//
//  ConnectionsTests.swift — a VM's connection log as netd reports it
//  (conns): each entry read strictly, anything netd should never send
//  dropped (its lines carry what a guest did), pages read with where the
//  next one starts.
//

import XCTest
@testable import Monad

final class ConnectionsTests: XCTestCase {
    private let github = NetConnection(proto: .tcp, address: "140.82.112.3", port: 443, verdict: .allowed,
                                       reason: .rule, rule: 2, opened: 7, refused: 1, asked: 0, active: 2,
                                       bytesOut: 1234, bytesIn: 56789, firstSeen: 120, lastSeen: 60, name: "github.com")

    func testAnEntryIsReadFromNetd() {
        XCTAssertEqual(NetConnection(token: "tcp,140.82.112.3,443,allow,rule:2,7,1,0,2,1234,56789,120,60,github.com"), github)
        let ping = NetConnection(token: "icmp,1.1.1.1,0,ask,monitor,0,0,3,0,0,0,0,0,-")
        XCTAssertEqual(ping?.proto, .icmp)
        XCTAssertEqual(ping?.verdict, .asked)
        XCTAssertEqual(ping?.reason, .monitor)
        XCTAssertNil(ping?.rule)
        XCTAssertEqual(ping?.asked, 3)
        XCTAssertNil(ping?.name, "\"-\": no name")
        let reasons: [(String, NetConnection.Reason)] = [("session", .session), ("lan", .lan), ("default", .byDefault)]
        for (text, reason) in reasons {
            let c = NetConnection(token: "udp,9.9.9.9,53,deny,\(text),0,1,0,0,0,0,5,5,-")
            XCTAssertEqual(c?.reason, reason, text)
            XCTAssertEqual(c?.verdict, .denied, text)
        }
    }

    func testWhatNetdShouldNeverSendIsDropped() {
        let fine = "tcp,1.2.3.4,80,allow,default,0,0,0,0,0,0,0,0,-"
        XCTAssertNotNil(NetConnection(token: fine))
        let bad = [
            "",
            "tcp,1.2.3.4,80,allow,default,0,0,0,0,0,0,0,0",
            fine + ",extra",
            "any,1.2.3.4,80,allow,default,0,0,0,0,0,0,0,0,-",
            "gre,1.2.3.4,80,allow,default,0,0,0,0,0,0,0,0,-",
            "tcp,300.2.3.4,80,allow,default,0,0,0,0,0,0,0,0,-",
            "tcp,1.2.3,80,allow,default,0,0,0,0,0,0,0,0,-",
            "tcp,1.2.3.4,70000,allow,default,0,0,0,0,0,0,0,0,-",
            "tcp,1.2.3.4,-1,allow,default,0,0,0,0,0,0,0,0,-",
            "icmp,1.2.3.4,7,ask,monitor,0,0,0,0,0,0,0,0,-",
            "tcp,1.2.3.4,80,maybe,default,0,0,0,0,0,0,0,0,-",
            "tcp,1.2.3.4,80,allow,because,0,0,0,0,0,0,0,0,-",
            "tcp,1.2.3.4,80,allow,rule:x,0,0,0,0,0,0,0,0,-",
            "tcp,1.2.3.4,80,allow,rule:-1,0,0,0,0,0,0,0,0,-",
            "tcp,1.2.3.4,80,allow,rule:64,0,0,0,0,0,0,0,0,-",
            "tcp,1.2.3.4,80,allow,default,-1,0,0,0,0,0,0,0,-",
            "tcp,1.2.3.4,80,allow,default,0,0,0,4294967296,0,0,0,0,-",
            "tcp,1.2.3.4,80,allow,default,0,0,0,0,18446744073709551616,0,0,0,-",
            "tcp,1.2.3.4,80,allow,default,0,0,0,0,1e3,0,0,0,-",
            "tcp,1.2.3.4,80,allow,default,0,0,0,0,0,0,0,-5,-",
            "tcp,1.2.3.4,80,allow,default,0,0,0,0,0,0,0,0,*.github.com",
            "tcp,1.2.3.4,80,allow,default,0,0,0,0,0,0,0,0,b!d.example",
            "tcp,1.2.3.4,80,allow,default,0,0,0,0,0,0,0,0," + String(repeating: "a", count: 254),
        ]
        for token in bad { XCTAssertNil(NetConnection(token: token), token) }
    }

    /// VM-to-VM traffic (peers): sender and receiver ports, frames, bytes,
    /// seconds since last seen, read as strictly as the log.
    func testAPeerEntryIsReadFromNetd() throws {
        XCTAssertEqual(NetPeer(token: "3,7,12,720,5"), NetPeer(from: 3, to: 7, frames: 12, bytes: 720, lastSeen: 5))
        let bad = ["", "3,7,12,720", "3,7,12,720,5,1", "3,3,1,60,0", "-1,7,1,60,0", "3,x,1,60,0", "3,7,0,60,0",
                   "2048,7,1,60,0", "3,7,1,18446744073709551616,0", "3,7,1,60,1e3", " 3,7,1,60,0"]
        for token in bad { XCTAssertNil(NetPeer(token: token), token) }
        let page = try XCTUnwrap(NetPeer.page("ok next=2 3,7,12,720,5 0,1,1,60,0"))
        XCTAssertEqual(page.next, 2)
        XCTAssertEqual(page.entries.count, 2)
        XCTAssertNil(NetPeer.page("ok next=2 3,7,12,720,5 nonsense 0,1,1,60,0"),
                     "a page with a bad (or cut) entry is refused whole, never read as fewer")
        XCTAssertEqual(NetPeer.page("ok next=0")?.entries, [])
        for reply in ["err unknown network", "ok", "ok next=x"] { XCTAssertNil(NetPeer.page(reply), reply) }
    }

    func testAPageOfTheLog() throws {
        let page = try XCTUnwrap(NetConnection.page(
            "ok next=2 tcp,140.82.112.3,443,allow,rule:2,7,1,0,2,1234,56789,120,60,github.com udp,9.9.9.9,53,deny,default,0,1,0,0,0,0,5,5,-"))
        XCTAssertEqual(page.next, 2)
        XCTAssertEqual(page.entries.first, github)
        XCTAssertEqual(page.entries.count, 2)
        XCTAssertEqual(NetConnection.page("ok next=0")?.entries, [])
        XCTAssertEqual(NetConnection.page("ok next=0")?.next, 0)
        XCTAssertNil(NetConnection.page("ok next=0 nonsense udp,9.9.9.9,53,deny,default,0,1,0,0,0,0,5,5,-"),
                     "a page with a bad entry is refused whole, never read as fewer")
        XCTAssertNil(NetConnection.page("ok next=0 udp,9.9.9.9,53,deny,default,0,1,0"), "a cut entry too")
        for reply in ["err unknown port", "ok", "ok next=x", "ok next=-1", "ok more=0", "ok next=70000"] {
            XCTAssertNil(NetConnection.page(reply), reply)
        }
    }
}
