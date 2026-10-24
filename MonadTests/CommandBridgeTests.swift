//
//  CommandBridgeTests.swift — stdio bridges (Phase 12): a Mac command a VM
//  can use, socat-style. Its settings: a name, the command as arguments
//  (an absolute executable, never a shell line), and where the VM reaches
//  it (a port on the guest's loopback, or a unix socket in the guest). On
//  the Mac it listens on a private unix socket, never a TCP port.
//

import XCTest
@testable import Monad

final class CommandBridgeTests: XCTestCase {
    private let id = UUID(uuidString: "12345678-9ABC-DEF0-1234-56789ABCDEF0")!

    private func config(_ bridges: [CommandBridge], forwards: [ForwardRule] = []) -> InstanceConfig {
        var c = InstanceConfig.defaults(name: "box")
        c.cpus = 2
        c.memoryGiB = 4
        c.bridges = bridges
        c.forwards = forwards
        return c
    }

    private func assertInvalid(_ c: InstanceConfig, _ expected: InstanceConfig.ValidationError, _ message: String = "",
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try c.validate(maxCPUs: 8, maxMemoryGiB: 16), message, file: file, line: line) { error in
            XCTAssertEqual(error as? InstanceConfig.ValidationError, expected, message, file: file, line: line)
        }
    }

    func testABridgeRunsAnAbsoluteCommandForAGuestPortOrSocket() throws {
        let mcp = CommandBridge(name: "Xcode MCP", command: ["/usr/bin/xcrun", "mcpbridge"], guestPort: 9000)
        let cat = CommandBridge(name: "cat", command: ["/bin/cat"], guestSocket: "/run/user/1000/cat.sock")
        let c = config([mcp, cat])
        XCTAssertNoThrow(try c.validate(maxCPUs: 8, maxMemoryGiB: 16))
        XCTAssertEqual(try InstanceConfig.decode(c.encoded()), c)
        XCTAssertFalse(String(decoding: try config([]).encoded(), as: UTF8.self).contains("bridges"), "written only when set")
    }

    func testBadBridgesAreRefused() {
        func bridge(name: String = "b", command: [String] = ["/bin/cat"], port: Int? = 9000, socket: String? = nil) -> CommandBridge {
            CommandBridge(name: name, command: command, guestPort: port, guestSocket: socket)
        }
        for name in ["", String(repeating: "n", count: 33), "a/b", "a\nb"] {
            assertInvalid(config([bridge(name: name)]), .bridgeName(name))
        }
        for command in [[], ["cat"], ["/bin/cat", "a\nb"], ["/bin/../bin/cat"], ["/bin/cat\u{0}"],
                        ["/bin/cat"] + Array(repeating: "x", count: 32), ["/bin/cat", String(repeating: "x", count: 1025)]] {
            assertInvalid(config([bridge(command: command)]), .bridgeCommand(command.first ?? ""))
        }
        assertInvalid(config([bridge(port: 80)]), .bridgeEndpoint("b"))
        assertInvalid(config([bridge(port: 70000)]), .bridgeEndpoint("b"))
        assertInvalid(config([bridge(port: nil)]), .bridgeEndpoint("b"), "neither a port nor a socket")
        assertInvalid(config([bridge(port: 9000, socket: "/run/b.sock")]), .bridgeEndpoint("b"), "both")
        for socket in ["run/b.sock", "/run/b:x.sock", "/run/b x.sock"] {
            assertInvalid(config([bridge(port: nil, socket: socket)]), .bridgeEndpoint("b"))
        }
        assertInvalid(config((0..<9).map { bridge(name: "b\($0)", port: 9000 + $0) }), .tooManyBridges)
        assertInvalid(config([bridge(name: "one"), bridge(name: "two")]), .duplicateGuestEndpoint("127.0.0.1:9000"))
        assertInvalid(config([bridge()], forwards: [ForwardRule(kind: .remote, hostPort: 8080, guestPort: 9000)]),
                      .duplicateGuestEndpoint("127.0.0.1:9000"), "a forward into the Mac already has that guest port")
    }

    /// The Mac side: a short socket and a log in the VM's private folder;
    /// the VM side: a remote forward to that socket.
    func testTheMacSideIsAPrivateSocket() {
        let paths = InstancePaths(name: "box", root: URL(fileURLWithPath: "/Users/dev/.monad/instances"))
        var b = CommandBridge(id: id, name: "mcp", command: ["/usr/bin/xcrun", "mcpbridge"], guestPort: 9000)
        XCTAssertEqual(b.socket(in: paths).path, "/Users/dev/.monad/instances/box/bridge-12345678.sock")
        XCTAssertEqual(b.log(in: paths).path, "/Users/dev/.monad/instances/box/bridge-12345678.log")
        XCTAssertEqual(b.spec(in: paths), SSHMux.Spec(flag: "-R", value: "127.0.0.1:9000:/Users/dev/.monad/instances/box/bridge-12345678.sock"))
        b.guestPort = nil
        b.guestSocket = "/run/user/1000/mcp.sock"
        XCTAssertEqual(b.spec(in: paths), SSHMux.Spec(flag: "-R", value: "/run/user/1000/mcp.sock:/Users/dev/.monad/instances/box/bridge-12345678.sock"))
        XCTAssertEqual(b.guestEndpoint, "/run/user/1000/mcp.sock")
    }

    /// Bridges, like forwards, change while the VM runs.
    func testBridgesChangeLive() {
        let old = config([])
        let new = config([CommandBridge(name: "cat", command: ["/bin/cat"], guestPort: 9000)])
        XCTAssertEqual(ConfigChange.all(from: old, to: new), ["bridges"])
        XCTAssertEqual(ConfigChange.restartOnly(from: old, to: new), [])
        XCTAssertEqual(ConfigChange.fixed(from: old, to: new), [])
    }
}
