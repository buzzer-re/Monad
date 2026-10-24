//
//  NetdTests.swift — mnd_netd on macOS: real sockets, kqueue, and macOS's
//  own ICMP socket behaviour. The VM is a datagram socket pair; the
//  destinations are servers on this Mac's LAN address.
//

import XCTest
@testable import Monad

private func ip4(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 { a << 24 | b << 16 | c << 8 | d }

private let vmIP = ip4(10, 77, 0, 10)
private let vmMAC = mnd_mac(b: (0x02, 0x4d, 0x4f, 0x4e, 0x00, 0x01))

final class NetdTests: XCTestCase {
    private var d: OpaquePointer!
    private var vm: Int32 = -1
    private var network: Int32 = -1
    private var gw = mnd_mac()
    private var lan: UInt32 = 0
    private var extra: [Int32] = []

    override func setUpWithError() throws {
        lan = try XCTUnwrap(Self.lanAddress(), "no LAN address")
        d = mnd_netd_create()
        let net = mnd_netd_net(d)
        var cfg = mnd_net_config()
        cfg.kind = MND_NET_NAT
        cfg.subnet = ip4(10, 77, 0, 0)
        cfg.prefix = 24
        network = mnd_net_add_network(net, &cfg)
        mnd_net_gateway(net, network, &gw, nil)
        var sv: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_DGRAM, 0, &sv), 0)
        vm = sv[1]
        _ = fcntl(vm, F_SETFL, fcntl(vm, F_GETFL) | O_NONBLOCK)
        let port = mnd_netd_add_port(d, network, vmMAC, sv[0])
        XCTAssertGreaterThanOrEqual(port, 0)
        var fw = mnd_fw_config()
        fw.allow_lan = true
        XCTAssertEqual(mnd_net_set_port_firewall(net, port, &fw), 0)
    }

    override func tearDown() {
        mnd_netd_destroy(d)
        close(vm)
        extra.forEach { close($0) }
    }

    private static func lanAddress() -> UInt32? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var i = list
        while let a = i {
            defer { i = a.pointee.ifa_next }
            let flags = Int32(a.pointee.ifa_flags)
            guard let sa = a.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_LOOPBACK == 0, flags & IFF_UP != 0 else { continue }
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            return UInt32(bigEndian: addr)
        }
        return nil
    }

    private static let blocked = "is blocked on this Mac (an outbound firewall such as LuLu or Little Snitch, "
        + "or Local Network privacy): allow Monad for any address and port"

    /// A plain TCP connection to this Mac's own LAN address, without netd,
    /// carrying one byte across.
    private static func tcpReachable(_ lan: UInt32) -> Bool {
        let lst = socket(AF_INET, SOCK_STREAM, 0), c = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(lst); close(c) }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(lst, $0, len) } }
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(lst, $0, &len) } }
        listen(lst, 1)
        a.sin_addr.s_addr = lan.bigEndian
        guard withUnsafePointer(to: &a, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(c, $0, len) } }) == 0
        else { return false }
        let s = accept(lst, nil, nil)
        guard s >= 0 else { return false }
        defer { close(s) }
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard Darwin.send(c, "x", 1, 0) == 1 else { return false }
        var b: UInt8 = 0
        return recv(s, &b, 1, 0) == 1
    }

    /// A plain datagram to this Mac's own LAN address, without netd. An
    /// outbound firewall or Local Network privacy can drop it silently.
    private static func udpReachable(_ lan: UInt32) -> Bool {
        let srv = socket(AF_INET, SOCK_DGRAM, 0), c = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(srv); close(c) }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(srv, $0, len) } }
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(srv, $0, &len) } }
        a.sin_addr.s_addr = lan.bigEndian
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(c, "x", 1, 0, $0, len) } }
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(srv, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var b: UInt8 = 0
        return recv(srv, &b, 1, 0) == 1
    }

    // MARK: - Helpers

    private func pump(_ ms: UInt64) {
        let end = mnd_loop_now() + ms
        while mnd_loop_now() < end { mnd_netd_run_once(d, mnd_loop_now() + 5) }
    }

    /// The next IPv4 frame for the VM with `proto`: (frame bytes, parsed IP).
    private func next(_ proto: UInt8, within ms: UInt64 = 2000) -> ([UInt8], mnd_ip)? {
        let end = mnd_loop_now() + ms
        var buf = [UInt8](repeating: 0, count: 2048)
        while mnd_loop_now() < end {
            let n = recv(vm, &buf, buf.count, 0)
            if n <= 0 { mnd_netd_run_once(d, mnd_loop_now() + 5); continue }
            let frame = Array(buf[0..<n])
            var eth = mnd_eth()
            var ip = mnd_ip()
            let ok = frame.withUnsafeBufferPointer { p -> Bool in
                mnd_eth_parse(p.baseAddress, n, &eth) == 0 && eth.type == MND_ETHERTYPE_IPV4 &&
                    mnd_ip_parse(eth.payload, eth.len, &ip) == 0 && ip.proto == proto
            }
            // The parsed pointers point into `frame`: re-parse from the kept copy.
            if ok { return (frame, ip) }
        }
        return nil
    }

    private func header(dst: UInt32) -> mnd_ip_hdr_spec {
        mnd_ip_hdr_spec(eth_dst: gw, eth_src: vmMAC, src: vmIP, dst: dst, ttl: 64, id: 0)
    }

    private func send(_ build: (UnsafeMutablePointer<UInt8>, Int) -> Int) {
        var f = [UInt8](repeating: 0, count: 1514)
        let n = f.withUnsafeMutableBufferPointer { build($0.baseAddress!, $0.count) }
        XCTAssertGreaterThan(n, 0)
        XCTAssertEqual(Darwin.send(vm, f, n, 0), n)
    }

    private func boundSocket(_ type: Int32) -> (Int32, UInt16) {
        let s = socket(AF_INET, type, 0)
        extra.append(s)
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(s, $0, len) } }
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
        return (s, UInt16(bigEndian: a.sin_port))
    }

    // MARK: - Tests

    func testUDPRoundTrip() throws {
        try XCTSkipUnless(Self.udpReachable(lan), "UDP to this Mac's LAN address " + Self.blocked)
        let (srv, port) = boundSocket(SOCK_DGRAM)
        var h = header(dst: lan)
        send { mnd_build_udp($0, $1, &h, 5000, port, "ping", 4) }
        var buf = [UInt8](repeating: 0, count: 64)
        var from = sockaddr_storage()
        var fl = socklen_t(MemoryLayout<sockaddr_storage>.size)
        var n = -1
        for _ in 0..<200 where n < 0 {
            pump(5)
            n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(srv, &buf, buf.count, 0, $0, &fl) }
            }
        }
        XCTAssertEqual(n, 4)
        _ = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(srv, "pong", 4, 0, $0, fl) }
        }
        let (frame, _) = try XCTUnwrap(next(UInt8(MND_IPPROTO_UDP)))
        XCTAssertEqual(Array(frame.suffix(4)), Array("pong".utf8))
    }

    func testTCPHandshakeAndData() throws {
        try XCTSkipUnless(Self.tcpReachable(lan), "TCP to this Mac's LAN address " + Self.blocked)
        let (lst, port) = boundSocket(SOCK_STREAM)
        XCTAssertEqual(listen(lst, 4), 0)
        var h = header(dst: lan)
        var syn = mnd_tcp_spec(sport: 40000, dport: port, seq: 1000, ack: 0, flags: UInt8(MND_TCP_SYN),
                               window: 65535, mss: 1400, wscale: -1)
        send { mnd_build_tcp($0, $1, &h, &syn, nil, 0) }
        let (synack, ip) = try XCTUnwrap(next(UInt8(MND_IPPROTO_TCP)))
        var t = mnd_tcp()
        var ipCopy = ip
        synack.withUnsafeBufferPointer { p in
            // Point the parsed IP at the kept frame, then parse TCP.
            var eth = mnd_eth()
            _ = mnd_eth_parse(p.baseAddress, synack.count, &eth)
            _ = mnd_ip_parse(eth.payload, eth.len, &ipCopy)
            _ = mnd_tcp_parse(&ipCopy, &t)
        }
        XCTAssertEqual(t.flags, UInt8(MND_TCP_SYN | MND_TCP_ACK))
        XCTAssertEqual(t.ack, 1001)
        var ack = mnd_tcp_spec(sport: 40000, dport: port, seq: 1001, ack: t.seq &+ 1, flags: UInt8(MND_TCP_ACK | MND_TCP_PSH),
                               window: 65535, mss: 0, wscale: -1)
        send { mnd_build_tcp($0, $1, &h, &ack, "hello", 5) }
        var c: Int32 = -1
        for _ in 0..<200 where c < 0 {
            pump(5)
            c = accept(lst, nil, nil)
        }
        XCTAssertGreaterThanOrEqual(c, 0)
        extra.append(c)
        var buf = [UInt8](repeating: 0, count: 16)
        var n = -1
        _ = fcntl(c, F_SETFL, fcntl(c, F_GETFL) | O_NONBLOCK)
        for _ in 0..<200 where n < 0 {
            pump(5)
            n = recv(c, &buf, buf.count, 0)
        }
        XCTAssertEqual(n, 5)
        XCTAssertEqual(Array(buf[0..<5]), Array("hello".utf8))
    }

    func testPingThroughMacICMPSockets() throws {
        var h = header(dst: lan)
        send { mnd_build_icmp($0, $1, &h, 8, 0, 0x77, 3, "abcdefgh", 8) }
        let (frame, _) = try XCTUnwrap(next(UInt8(MND_IPPROTO_ICMP)), "no echo reply (macOS ICMP socket)")
        // Ethernet 14 + IP 20 + ICMP header 8 + data 8.
        XCTAssertEqual(frame.count, 50)
        XCTAssertEqual(frame[34], 0) // echo reply
        XCTAssertEqual(Array(frame[38..<42]), [0x00, 0x77, 0x00, 0x03]) // the VM's id and seq
        XCTAssertEqual(Array(frame[42...]), Array("abcdefgh".utf8))
    }

    func testNothingStaysOpen() {
        let (srv, port) = boundSocket(SOCK_DGRAM)
        _ = srv
        var h = header(dst: lan)
        for i in 0..<5 { send { mnd_build_udp($0, $1, &h, UInt16(6000 + i), port, "x", 1) } }
        pump(50)
        XCTAssertEqual(mnd_netd_open_sockets(d), 5)
        mnd_netd_remove_port(d, 0)
        XCTAssertEqual(mnd_netd_open_sockets(d), 0)
    }
}
