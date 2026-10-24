//
//  BridgeServerTests.swift — MonadHost's side of a stdio bridge (Phase 12):
//  a private unix socket, and for each connection the bridge's command
//  with the connection as its stdin and stdout, stderr to the bridge's
//  log, a plain environment, a cap on commands at once, and the commands
//  ended when the bridge stops. Real sockets and processes.
//

import XCTest
@testable import Monad

final class BridgeServerTests: XCTestCase {
    private var dir: URL!
    private var servers: [BridgeServer] = []
    private var socketPath: String { dir.appendingPathComponent("b.sock").path }
    private var logPath: String { dir.appendingPathComponent("b.log").path }

    override func setUpWithError() throws {
        // Short: a unix socket path has 104 bytes.
        var template = Array("/tmp/mb-XXXXXX".utf8CString)
        let made = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress) }
        dir = URL(fileURLWithPath: String(cString: try XCTUnwrap(made)), isDirectory: true)
    }

    override func tearDown() {
        servers.forEach { $0.stop() }
        try? FileManager.default.removeItem(at: dir)
    }

    private func server(_ command: [String], connections: Int = 4, logBytes: Int = 1 << 20,
                        environment: [String: String] = ["PATH": "/usr/bin:/bin"]) throws -> BridgeServer {
        let s = BridgeServer(command: command, socket: URL(fileURLWithPath: socketPath), log: URL(fileURLWithPath: logPath),
                             maxConnections: connections, maxLogBytes: logBytes, environment: environment)
        servers.append(s)
        try s.start()
        return s
    }

    private func connect() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            socketPath.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        let ok = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else {
            close(fd)
            throw TestError("connect: errno \(errno)")
        }
        return fd
    }

    private func send(_ fd: Int32, _ text: String) {
        _ = text.utf8CString.withUnsafeBytes { write(fd, $0.baseAddress, $0.count - 1) }
    }

    /// What comes until the other side closes (or `timeout` passes).
    private func readAll(_ fd: Int32, timeout: TimeInterval = 5) -> String {
        var out = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 100) > 0 else { continue }
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            out.append(contentsOf: buffer[0..<n])
        }
        return String(decoding: out, as: UTF8.self)
    }

    private var log: String { (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "" }

    func testEachConnectionRunsTheCommandWithTheConnectionAsItsStdio() throws {
        _ = try server(["/bin/cat"])
        let a = try connect(), b = try connect()
        defer { close(a); close(b) }
        send(a, "one\n")
        send(b, "two\n")
        shutdown(a, SHUT_WR)
        shutdown(b, SHUT_WR)
        XCTAssertEqual(readAll(a), "one\n")
        XCTAssertEqual(readAll(b), "two\n", "a command of its own")
    }

    func testErrorsGoToTheLog() async throws {
        _ = try server(["/bin/sh", "-c", "echo oops >&2"])
        let a = try connect()
        defer { close(a) }
        XCTAssertEqual(readAll(a), "", "nothing on the connection")
        await assertEventually("log: \(log)") { self.log.contains("oops") }
    }

    /// The command gets the variables a program needs, never the rest of
    /// MonadHost's environment.
    func testTheCommandGetsAPlainEnvironment() throws {
        _ = try server(["/usr/bin/env"], environment: ["PATH": "/usr/bin:/bin", "HOME": "/Users/dev", "LANG": "en_US.UTF-8",
                                                       "AWS_SECRET_ACCESS_KEY": "nope", "DYLD_INSERT_LIBRARIES": "/x.dylib"])
        let a = try connect()
        defer { close(a) }
        let lines = Set(readAll(a).split(separator: "\n").map(String.init))
        XCTAssertEqual(lines, ["PATH=/usr/bin:/bin", "HOME=/Users/dev", "LANG=en_US.UTF-8"])
    }

    func testConnectionsBeyondTheCapAreClosed() async throws {
        let s = try server(["/bin/cat"], connections: 1)
        let a = try connect()
        defer { close(a) }
        send(a, "x")
        await assertEventually("running \(s.running)") { s.running == 1 }
        let b = try connect()
        defer { close(b) }
        XCTAssertEqual(readAll(b, timeout: 2), "", "closed at once")
        await assertEventually("log: \(log)") { self.log.contains("refused") }
        send(a, "y")
        shutdown(a, SHUT_WR)
        XCTAssertEqual(readAll(a), "xy", "the first one goes on")
    }

    func testStoppingEndsTheCommandsAndRemovesTheSocket() async throws {
        let s = try server(["/bin/cat"])
        let a = try connect()
        defer { close(a) }
        await assertEventually("running \(s.running)") { s.running == 1 }
        s.stop()
        XCTAssertEqual(readAll(a), "", "the command ended, so the connection did")
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
        await assertEventually("running \(s.running)") { s.running == 0 }
    }

    func testTheSocketIsTheUsersOnly() throws {
        _ = try server(["/bin/cat"])
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: socketPath)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
    }

    /// A socket left by an earlier MonadHost is replaced; anything else
    /// there is not Monad's to remove.
    func testOnlyASocketIsReplaced() throws {
        // A socket bound and closed, as a MonadHost that crashed leaves it.
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            socketPath.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(stale)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
        XCTAssertNoThrow(try server(["/bin/cat"]), "a stale socket")
        servers.forEach { $0.stop() }
        servers = []
        try Data("mine".utf8).write(to: URL(fileURLWithPath: socketPath))
        XCTAssertThrowsError(try server(["/bin/cat"]))
        XCTAssertEqual(try String(contentsOfFile: socketPath, encoding: .utf8), "mine")
    }

    func testATooLongSocketPathIsRefused() {
        let long = dir.appendingPathComponent(String(repeating: "s", count: 110)).path
        let s = BridgeServer(command: ["/bin/cat"], socket: URL(fileURLWithPath: long), log: URL(fileURLWithPath: logPath),
                             maxConnections: 1, maxLogBytes: 1 << 20, environment: [:])
        XCTAssertThrowsError(try s.start())
    }

    func testTheLogIsBounded() throws {
        try Data(repeating: 0x41, count: 4096).write(to: URL(fileURLWithPath: logPath))
        _ = try server(["/bin/sh", "-c", "echo late >&2"], logBytes: 1024)
        let a = try connect()
        defer { close(a) }
        _ = readAll(a)
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: logPath)[.size] as? NSNumber).intValue
        XCTAssertLessThan(size, 1024 + 512, "started again once it passed its size")
    }
}
