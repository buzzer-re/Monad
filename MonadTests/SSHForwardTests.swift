//
//  SSHForwardTests.swift — a port carried between a VM and an SSH host:
//  the two forwards it is made of (one on each ssh master, joined by a
//  socket in the VM's folder, never a TCP port of the Mac), and what cannot
//  be one.
//

import XCTest
@testable import Monad

final class SSHForwardTests: XCTestCase {
    private let paths = InstancePaths(name: "web", root: URL(fileURLWithPath: "/Users/dev/.monad/instances"))
    private let id = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!
    private let socket = "/Users/dev/.monad/instances/web/sshfwd-aaaaaaaa.sock"

    private func forward(_ direction: SSHForward.Direction, guest: Int, remoteHost: String = "127.0.0.1",
                         remote: Int) -> SSHForward {
        SSHForward(id: id, sshHost: "box", direction: direction, guestPort: guest, remoteHost: remoteHost, remotePort: remote)
    }

    /// A port the server reaches, in the VM: the VM's sshd listens on its
    /// loopback, the SSH host's master connects on from the Mac's socket.
    func testAServerPortIntoTheVM() {
        let f = forward(.intoVM, guest: 5432, remoteHost: "db.internal", remote: 5432)
        XCTAssertEqual(f.socket(in: paths).path, socket)
        XCTAssertEqual(f.vmSpec(in: paths), SSHMux.Spec(flag: "-R", value: "127.0.0.1:5432:\(socket)"))
        XCTAssertEqual(f.hostSpec(in: paths), SSHMux.Spec(flag: "-L", value: "\(socket):db.internal:5432"))
        XCTAssertNil(f.vmBoundSocket(in: paths), "the SSH host's master makes the socket")
    }

    /// A VM port on the server: the server listens, the VM's master makes
    /// the socket on the Mac and connects on into the VM.
    func testAVMPortOntoTheServer() {
        let f = forward(.ontoHost, guest: 8000, remote: 18000)
        XCTAssertEqual(f.vmSpec(in: paths), SSHMux.Spec(flag: "-L", value: "\(socket):127.0.0.1:8000"))
        XCTAssertEqual(f.hostSpec(in: paths), SSHMux.Spec(flag: "-R", value: "127.0.0.1:18000:\(socket)"))
        XCTAssertEqual(f.vmBoundSocket(in: paths)?.path, socket)
    }

    /// The port a forward makes the server listen on: the server's agent
    /// reports it, and it must not come back onto the Mac as a port of its own.
    func testOnlyAVMPortOnTheServerMakesTheServerListen() {
        XCTAssertEqual(forward(.ontoHost, guest: 8000, remote: 18000).hostListenPort, 18000)
        XCTAssertNil(forward(.intoVM, guest: 5432, remote: 5432).hostListenPort)
    }

    func testIPv6AddressesAreBracketed() {
        XCTAssertEqual(forward(.intoVM, guest: 8080, remoteHost: "2001:db8::5", remote: 80).hostSpec(in: paths).value,
                       "\(socket):[2001:db8::5]:80")
        XCTAssertEqual(forward(.ontoHost, guest: 8080, remoteHost: "::1", remote: 80).hostSpec(in: paths).value,
                       "[::1]:80:\(socket)")
    }

    /// Nothing in a forward can reshape ssh's spec or name another place.
    func testWhatCannotBeAForward() {
        XCTAssertNil(forward(.intoVM, guest: 5432, remoteHost: "db.internal", remote: 5432).problem)
        XCTAssertNil(forward(.ontoHost, guest: 80, remoteHost: "0.0.0.0", remote: 8080).problem,
                     "any VM port, on an address of the server's")
        var f = forward(.intoVM, guest: 5432, remote: 5432)
        f.sshHost = "no good"
        XCTAssertEqual(f.problem, "“no good” is not an SSH host's name.")
        XCTAssertEqual(forward(.intoVM, guest: 5432, remote: 0).problem, "0 is not a valid port (1–65535).")
        XCTAssertEqual(forward(.ontoHost, guest: 70000, remote: 80).problem, "70000 is not a valid port (1–65535).")
        XCTAssertEqual(forward(.intoVM, guest: 80, remote: 80).problem, "The port in the VM is from 1024 to 65535.")
        for bad in ["db:5432", "a b", "", "db.internal\n", "/tmp/x.sock"] {
            XCTAssertEqual(forward(.intoVM, guest: 5432, remoteHost: bad, remote: 5432).problem,
                           "“\(bad)” is not a host name or address.", bad)
        }
        for bad in ["localhost", "", "127.0.0.1:1", "127.0.0.1\n"] {
            XCTAssertEqual(forward(.ontoHost, guest: 8000, remoteHost: bad, remote: 8000).problem,
                           "“\(bad)” is not an address for the SSH host to listen on.", bad)
        }
    }

    func testTheSameRouteWhateverItsIDOrSwitch() {
        let a = forward(.intoVM, guest: 5432, remoteHost: "db.internal", remote: 5432)
        var b = a
        b.id = UUID()
        b.enabled = false
        XCTAssertTrue(a.sameRoute(b))
        b.remotePort = 5433
        XCTAssertFalse(a.sameRoute(b))
        XCTAssertFalse(a.sameRoute(forward(.ontoHost, guest: 5432, remoteHost: "db.internal", remote: 5432)))
    }

    func testAFileMayLeaveOutWhatHasADefault() throws {
        let json = #"{"sshHost": "box", "direction": "ontoHost", "guestPort": 8000, "remotePort": 18000}"#
        let f = try JSONDecoder().decode(SSHForward.self, from: Data(json.utf8))
        XCTAssertEqual(f.remoteHost, "127.0.0.1")
        XCTAssertTrue(f.enabled)
        XCTAssertTrue(f.sameRoute(forward(.ontoHost, guest: 8000, remote: 18000)))
        XCTAssertEqual(try JSONDecoder().decode(SSHForward.self, from: JSONEncoder().encode(f)), f)
    }
}
