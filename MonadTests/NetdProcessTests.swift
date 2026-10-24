//
//  NetdProcessTests.swift — the real netd process on macOS: MonadHost's own
//  binary started with --netd (mnd_netd_spawn), its sandbox, and its control
//  channel.
//

import XCTest
@testable import Monad

/// Tells the loopback servers to stop (read and written from two threads).
private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

final class NetdProcessTests: XCTestCase {
    private var hostPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MonadHost").path
    }

    private func loopbackSocket(_ type: Int32) -> (Int32, UInt16) {
        let s = socket(AF_INET, type, 0)
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(s, $0, len) } }
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
        return (s, UInt16(bigEndian: a.sin_port))
    }

    func testTheSandboxAllowsTheNetworkAndNothingElse() throws {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: hostPath), hostPath)
        // A UDP echo and a TCP greeter on loopback, served while the check runs.
        let (udp, udpPort) = loopbackSocket(SOCK_DGRAM)
        let (tcp, tcpPort) = loopbackSocket(SOCK_STREAM)
        defer { close(udp); close(tcp) }
        listen(tcp, 4)
        // A unix socket like an ssh agent's or another VM's ssh.sock.
        let unixPath = "/tmp/mnd-\(UUID().uuidString.prefix(8)).sock"
        let unixListener = socket(AF_UNIX, SOCK_STREAM, 0)
        var ua = sockaddr_un()
        ua.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &ua.sun_path) { buf in unixPath.utf8CString.withUnsafeBytes { buf.copyMemory(from: $0) } }
        let bound = withUnsafePointer(to: &ua) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(unixListener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(unixListener, 4), 0)
        defer { close(unixListener); unlink(unixPath) }
        let done = DispatchSemaphore(value: 0)
        let stop = StopFlag()
        DispatchQueue.global().async {
            var tv = timeval(tv_sec: 0, tv_usec: 100_000)
            setsockopt(udp, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            _ = fcntl(tcp, F_SETFL, fcntl(tcp, F_GETFL) | O_NONBLOCK)
            while !stop.isSet {
                var buf = [UInt8](repeating: 0, count: 16)
                var from = sockaddr_storage()
                var fl = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let n = withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(udp, &buf, buf.count, 0, $0, &fl) }
                }
                if n > 0 {
                    _ = withUnsafeMutablePointer(to: &from) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(udp, buf, n, 0, $0, fl) }
                    }
                }
                let c = accept(tcp, nil, nil)
                if c >= 0 {
                    _ = Darwin.send(c, "hi", 2, 0)
                    usleep(200_000)
                    close(c)
                }
            }
            done.signal()
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: hostPath)
        process.arguments = ["--netd-sandbox-check", String(udpPort), String(tcpPort), unixPath]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        stop.set()
        done.wait()
        let report = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, report)
        for line in ["udp ok", "tcp ok", "icmp ok", "file-read-denied ok", "file-write-denied ok", "fork-denied ok",
                     "listen-denied ok", "unix-connect-denied ok", "udp-listener denied"] {
            XCTAssertTrue(report.contains(line), "\(line) missing in:\n\(report)")
        }
    }

    func testTheNetdProcessServesItsControlChannel() throws {
        var sv: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sv), 0)
        let pid = mnd_netd_spawn(hostPath, sv[1])
        close(sv[1])
        XCTAssertGreaterThan(pid, 0)
        let control = sv[0]
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(control, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var pending = ""
        func reply() -> String? {
            while true {
                if let nl = pending.firstIndex(of: "\n") {
                    let line = String(pending[..<nl])
                    pending.removeSubrange(...nl)
                    return line
                }
                var buf = [UInt8](repeating: 0, count: 512)
                let n = recv(control, &buf, buf.count, 0)
                if n <= 0 { return nil }
                pending += String(decoding: buf[0..<n], as: UTF8.self)
            }
        }
        XCTAssertEqual(mnd_netd_send_command(control, "ping", -1), 0)
        XCTAssertEqual(reply(), "ok pong")
        XCTAssertEqual(mnd_netd_send_command(control, "network nat 10.77.0.0/24", -1), 0)
        XCTAssertEqual(reply(), "ok 0")
        // A VM's NIC goes across with its command; a frame from the VM is counted.
        var nic: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_DGRAM, 0, &nic), 0)
        XCTAssertEqual(mnd_netd_send_command(control, "port 0 02:4d:4f:4e:00:01", nic[0]), 0)
        close(nic[0])
        defer { close(nic[1]) }
        XCTAssertEqual(reply(), "ok 0")
        var frame = [UInt8](repeating: 0, count: 64)
        let mac = mnd_mac(b: (0x02, 0x4d, 0x4f, 0x4e, 0x00, 0x01))
        let n = frame.withUnsafeMutableBufferPointer {
            mnd_build_arp($0.baseAddress, $0.count, 1, MND_MAC_BROADCAST, mac, 0, mnd_mac(), 10 << 24 | 77 << 16 | 1)
        }
        XCTAssertEqual(Darwin.send(nic[1], frame, n, 0), n)
        var answer = [UInt8](repeating: 0, count: 128)
        var rtv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(nic[1], SOL_SOCKET, SO_RCVTIMEO, &rtv, socklen_t(MemoryLayout<timeval>.size))
        XCTAssertGreaterThan(recv(nic[1], &answer, answer.count, 0), 0, "the gateway answers ARP")
        XCTAssertEqual(mnd_netd_send_command(control, "stats 0", -1), 0)
        XCTAssertEqual(reply()?.hasPrefix("ok rx=1 tx=1 "), true)
        // MonadHost going away ends netd.
        close(control)
        var status: Int32 = -1
        for _ in 0..<300 {
            if waitpid(pid, &status, WNOHANG) == pid { break }
            usleep(10_000)
        }
        XCTAssertEqual(status, 0, "netd exits cleanly when its channel closes")
    }
}
