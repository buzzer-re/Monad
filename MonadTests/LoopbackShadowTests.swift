//
//  LoopbackShadowTests.swift — why ForwardManager looks for Mac programs on a
//  port before auto-forwarding it (F-03): on macOS, ssh's -L bind of
//  127.0.0.1:port (with SO_REUSEADDR, as OpenSSH does) succeeds next to a
//  server of the same user listening on all addresses, and the Mac's own
//  connections to 127.0.0.1:port then reach the VM. ssh reports no error.
//  If macOS ever refuses that bind, this fails: the check is then redundant.
//

import XCTest

final class LoopbackShadowTests: XCTestCase {
    /// A listening socket: IPv4 or dual-stack IPv6, on the wildcard or 127.0.0.1.
    private func listener(v6: Bool, wildcard: Bool, reuse: Bool, port: UInt16) -> Int32? {
        let s = socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        var one: Int32 = 1, zero: Int32 = 0
        if reuse { setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size)) }
        var ok: Int32
        if v6 {
            setsockopt(s, IPPROTO_IPV6, IPV6_V6ONLY, &zero, socklen_t(MemoryLayout<Int32>.size))
            var a = sockaddr_in6()
            a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            a.sin6_family = sa_family_t(AF_INET6)
            a.sin6_port = port.bigEndian
            a.sin6_addr = wildcard ? in6addr_any : in6addr_loopback
            ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        } else {
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = port.bigEndian
            a.sin_addr.s_addr = (wildcard ? INADDR_ANY : INADDR_LOOPBACK).bigEndian
            ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        guard ok == 0, listen(s, 4) == 0 else {
            close(s)
            return nil
        }
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
        return s
    }

    /// Connects to 127.0.0.1:port; which of `candidates` accepted it.
    private func whoAccepts(port: UInt16, _ candidates: [(String, Int32)]) -> String {
        let c = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(c) }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(c, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard r == 0 else { return "nobody (connect errno \(errno))" }
        usleep(50_000)
        for (name, s) in candidates {
            let got = accept(s, nil, nil)
            if got >= 0 {
                close(got)
                return name
            }
        }
        return "nobody accepted"
    }

    func testSSHTakesTheLoopbackOfAMacServerOnAllAddresses() {
        let servers: [(String, Bool, Bool)] = [  // name, v6 dual-stack, SO_REUSEADDR
            ("IPv4 0.0.0.0 with SO_REUSEADDR (node, most servers)", false, true),
            ("IPv4 0.0.0.0", false, false),
            ("IPv6 :: dual-stack with SO_REUSEADDR (python3 -m http.server)", true, true),
            ("IPv6 :: dual-stack", true, false),
        ]
        for (i, (name, v6, reuse)) in servers.enumerated() {
            let port = UInt16(47_300 + i)
            guard let mac = listener(v6: v6, wildcard: true, reuse: reuse, port: port) else {
                XCTFail("\(name): the Mac server could not listen")
                continue
            }
            defer { close(mac) }
            // ssh -L 127.0.0.1:port: IPv4 loopback with SO_REUSEADDR.
            guard let ssh = listener(v6: false, wildcard: false, reuse: true, port: port) else {
                XCTFail("\(name): macOS now refuses ssh's bind (errno \(errno)), F-03's check is redundant")
                continue
            }
            defer { close(ssh) }
            XCTAssertEqual(whoAccepts(port: port, [("the VM", ssh), ("the Mac server", mac)]), "the VM", name)
        }
    }
}
