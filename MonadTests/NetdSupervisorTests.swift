//
//  NetdSupervisorTests.swift — MonadHost's side of monad-netd, against the
//  real netd process: networks created on demand, VM NICs attached and
//  detached behind their VM's firewall, DNS through the Mac's nameservers,
//  and recovery after netd dies.
//

import XCTest
@testable import Monad

private struct FixedHostInfo: HostNetworkInfo {
    var nameservers: [String] = []
    var localNetworks: [String] = []
}

@MainActor
final class NetdSupervisorTests: XCTestCase {
    private var store: NetworkStore!
    private var tags: FirewallTagStore!
    private var supervisor: NetdSupervisor!

    private var hostPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MonadHost").path }

    override func setUp() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("netd-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        store = NetworkStore(directory: dir.appendingPathComponent("networks"))
        tags = FirewallTagStore(directory: dir.appendingPathComponent("tags"))
    }

    override func tearDown() async throws {
        supervisor?.shutDown()
        supervisor = nil
    }

    private func start(_ info: FixedHostInfo = FixedHostInfo()) -> NetdSupervisor {
        supervisor = NetdSupervisor(executable: hostPath, store: store, tags: tags, hostInfo: info)
        return supervisor
    }

    private static let mac = mnd_mac(b: (0x02, 0x4d, 0x4f, 0x4e, 0x00, 0x21))
    private static let macString = "02:4d:4f:4e:00:21"

    /// A DHCP discover from the VM's end; the address offered, if any.
    private func offer(_ handle: FileHandle, within seconds: Int = 3, mac given: mnd_mac? = nil) -> UInt32? {
        let mac = given ?? Self.mac
        let fd = handle.fileDescriptor
        var payload = [UInt8](repeating: 0, count: 600)
        var m = mnd_dhcp()
        m.op = 1
        m.xid = 0x5151
        m.chaddr = mac
        m.type = UInt8(MND_DHCP_DISCOVER)
        let pn = payload.withUnsafeMutableBufferPointer { mnd_dhcp_build($0.baseAddress, $0.count, &m) }
        var frame = [UInt8](repeating: 0, count: 1514)
        var h = mnd_ip_hdr_spec(eth_dst: MND_MAC_BROADCAST, eth_src: mac, src: 0, dst: 0xffff_ffff, ttl: 64, id: 0)
        let n = frame.withUnsafeMutableBufferPointer { f in
            payload.withUnsafeBufferPointer { p in mnd_build_udp(f.baseAddress, f.count, &h, 68, 67, p.baseAddress, pn) }
        }
        guard Darwin.send(fd, frame, n, 0) == n else { return nil }
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8](repeating: 0, count: 1514)
        let got = recv(fd, &buf, buf.count, 0)
        guard got > 0 else { return nil }
        return buf.withUnsafeBufferPointer { b -> UInt32? in
            var eth = mnd_eth(), ip = mnd_ip(), udp = mnd_udp(), reply = mnd_dhcp()
            guard mnd_eth_parse(b.baseAddress, got, &eth) == 0, mnd_ip_parse(eth.payload, eth.len, &ip) == 0,
                  mnd_udp_parse(&ip, &udp) == 0, mnd_dhcp_parse(udp.payload, udp.len, &reply) == 0,
                  reply.type == UInt8(MND_DHCP_OFFER) else { return nil }
            return reply.yiaddr
        }
    }

    func testAVMGetsAnAddressOnTheDefaultNetwork() async throws {
        let s = start()
        let nic = try await s.attach(vm: "a", network: "default", mac: Self.macString, firewall: VMFirewall())
        let address = try XCTUnwrap(offer(nic.handle), "no DHCP offer through netd")
        XCTAssertEqual(address >> 8, 0x0A4D00, "an address in 10.77.0.0/24")
        nic.detach()
    }

    /// Settings › Logs: each command to netd and its reply.
    func testNetdCommandsAreLogged() async throws {
        let tmp = TempDir()
        let debugLog = DebugLog(process: "MonadHost", directory: tmp.url, settings: tmp.url.appendingPathComponent("l.json"))
        debugLog.setEnabled(true)
        supervisor = NetdSupervisor(executable: hostPath, store: store, tags: tags, hostInfo: FixedHostInfo(), debugLog: debugLog)
        let nic = try await supervisor.attach(vm: "a", network: "default", mac: Self.macString, firewall: VMFirewall())
        nic.detach()
        try await supervisor.sync()
        debugLog.flush()
        let t = (try? String(contentsOf: debugLog.currentFile, encoding: .utf8)) ?? ""
        XCTAssertTrue(t.contains("netd: started monad-netd"), t)
        XCTAssertTrue(t.range(of: #"netd: port \d+ 02:4d:4f:4e:00:21 → ok \d+"#, options: .regularExpression) != nil, t)
        XCTAssertTrue(t.contains("netd: a joins default"), t)
        XCTAssertTrue(t.range(of: #"netd: unport \d+ → ok"#, options: .regularExpression) != nil, t)
    }

    func testUnknownNetworksAndBadMACsAreRefused() async throws {
        let s = start()
        do {
            _ = try await s.attach(vm: "a", network: "nowhere", mac: Self.macString, firewall: VMFirewall())
            XCTFail("attached to a network that does not exist")
        } catch {}
        do {
            _ = try await s.attach(vm: "a", network: "default", mac: "not-a-mac", firewall: VMFirewall())
            XCTFail("attached with an invalid MAC")
        } catch {}
    }

    func testADetachedNICIsOffTheNetwork() async throws {
        let s = start()
        let nic = try await s.attach(vm: "a", network: "default", mac: Self.macString, firewall: VMFirewall())
        XCTAssertNotNil(offer(nic.handle))
        nic.detach()
        try await s.sync()
        XCTAssertNil(offer(nic.handle, within: 1), "netd let go of the port")
    }

    /// A NIC let go and a new one asked for at once (a macOS VM back from
    /// recovery, booting as usual): netd lets go of the old port first.
    func testANICLetGoAndAskedForAgainAtOnceIsMade() async throws {
        let s = start()
        let old = try await s.attach(vm: "a", network: "default", mac: Self.macString, firewall: VMFirewall())
        XCTAssertNotNil(offer(old.handle))
        old.detach()
        let new = try await s.attach(vm: "a", network: "default", mac: Self.macString, firewall: VMFirewall())
        XCTAssertNotNil(offer(new.handle))
        new.detach()
    }

    /// A VM that gets a new machine (a shared folder added, say) attaches
    /// again before its old machine's NIC is let go: the new port replaces
    /// the old one (netd keeps one port per MAC).
    func testAVMAttachingAgainReplacesItsOldPort() async throws {
        let s = start()
        let old = try await s.attach(vm: "a", network: "default", mac: Self.macString, firewall: VMFirewall())
        XCTAssertNotNil(offer(old.handle))
        let new = try await s.attach(vm: "a", network: "default", mac: Self.macString, firewall: VMFirewall())
        XCTAssertNotNil(offer(new.handle), "the new machine's NIC is on the network")
        XCTAssertNil(offer(old.handle, within: 1), "the old one is not")
        old.detach() // the old machine goes away later: the new port stays
        try await s.sync()
        XCTAssertNotNil(offer(new.handle))
        new.detach()
    }

    func testNetworksAreCreatedFromTheirDefinitions() async throws {
        try store.save(NetworkDefinition(name: "lab", kind: .internal, subnet: "192.168.77.0/24"))
        let s = start()
        let nic = try await s.attach(vm: "a", network: "lab", mac: Self.macString, firewall: VMFirewall())
        let address = try XCTUnwrap(offer(nic.handle))
        XCTAssertEqual(address >> 8, 0xC0A84D, "an address in 192.168.77.0/24")
        nic.detach()
    }

    /// VMs joining one network at the same moment (four made and started
    /// together) share one switch and its leases: each gets its own address.
    /// netd was asked for the network once per VM, and each VM sat alone on
    /// its copy, all with the first address.
    func testVMsJoiningAtOnceShareOneNetwork() async throws {
        try store.save(NetworkDefinition(name: "swarm", kind: .nat, subnet: "10.79.0.0/24"))
        let s = start()
        let macs = (0..<4).map { mnd_mac(b: (0x02, 0x4d, 0x4f, 0x4e, 0x01, UInt8($0))) }
        let nics = try await withThrowingTaskGroup(of: (Int, NICAttachment).self) { group in
            for i in 0..<4 {
                group.addTask { @MainActor in
                    (i, try await s.attach(vm: "swarm-\(i)", network: "swarm", mac: String(format: "02:4d:4f:4e:01:%02x", i),
                                           firewall: VMFirewall()))
                }
            }
            var out: [Int: NICAttachment] = [:]
            for try await (i, nic) in group { out[i] = nic }
            return out
        }
        var addresses: [UInt32] = []
        for i in 0..<4 { addresses.append(try XCTUnwrap(offer(nics[i]!.handle, mac: macs[i]), "no offer for swarm-\(i)")) }
        XCTAssertEqual(Set(addresses).count, 4, "one address each: \(addresses.map { String($0 & 0xff) })")
        nics.values.forEach { $0.detach() }
    }

    /// VMs that start at boot: one starts netd, the next joins while netd
    /// is still being set up. Each port is made once ("port refused", for
    /// the second asking of a MAC, failed them).
    func testAVMJoiningWhileNetdStartsGetsItsPortOnce() async throws {
        let s = start()
        let macs = [mnd_mac(b: (0x02, 0x4d, 0x4f, 0x4e, 0x02, 0x01)), mnd_mac(b: (0x02, 0x4d, 0x4f, 0x4e, 0x02, 0x02))]
        let first = Task { @MainActor in
            try await s.attach(vm: "a", network: "default", mac: "02:4d:4f:4e:02:01", firewall: VMFirewall())
        }
        while s.processID == nil { await Task.yield() }
        let b = try await s.attach(vm: "b", network: "default", mac: "02:4d:4f:4e:02:02", firewall: VMFirewall())
        let a = try await first.value
        XCTAssertNotNil(offer(a.handle, mac: macs[0]), "a's NIC works")
        XCTAssertNotNil(offer(b.handle, mac: macs[1]), "b's NIC works")
        a.detach()
        b.detach()
    }

    func testVMsKeepTheirNetworkWhenNetdIsRestarted() async throws {
        let s = start()
        let nic = try await s.attach(vm: "a", network: "default", mac: Self.macString, firewall: VMFirewall())
        XCTAssertNotNil(offer(nic.handle))
        let first = try XCTUnwrap(s.processID)
        kill(first, SIGKILL)
        // The supervisor notices, starts a new netd and hands it the same NIC.
        var recovered: UInt32?
        for _ in 0..<40 where recovered == nil {
            try await Task.sleep(nanoseconds: 250_000_000)
            if let pid = s.processID, pid != first { recovered = offer(nic.handle, within: 1) }
        }
        XCTAssertNotNil(recovered, "the VM's NIC works again after netd came back")
        nic.detach()
    }

    func testDNSGoesToTheMacsNameservers() async throws {
        // A nameserver on loopback that answers every query with 93.184.216.34.
        let ns = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(ns) }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(ns, $0, len) } }
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(ns, $0, &len) } }
        let port = UInt16(bigEndian: a.sin_port)
        let s = start(FixedHostInfo(nameservers: ["127.0.0.1:\(port)"]))
        let nic = try await s.attach(vm: "a", network: "default", mac: Self.macString, firewall: VMFirewall())
        let vmIP = try XCTUnwrap(offer(nic.handle))
        // The VM asks the gateway (10.77.0.1) for example.com.
        let query: [UInt8] = [0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 7] + Array("example".utf8) + [3] + Array("com".utf8)
            + [0, 0, 1, 0, 1]
        var frame = [UInt8](repeating: 0, count: 1514)
        var gw = mnd_mac()
        var h = mnd_ip_hdr_spec(eth_dst: gw, eth_src: Self.mac, src: vmIP, dst: 0x0A4D_0001, ttl: 64, id: 0)
        // The gateway's MAC comes from netd's answer to ARP; netd's gateway MACs are 02:4d:4e:47:00:<net>.
        gw = mnd_mac(b: (0x02, 0x4d, 0x4e, 0x47, 0x00, 0x00))
        h.eth_dst = gw
        let n = frame.withUnsafeMutableBufferPointer { f in
            query.withUnsafeBufferPointer { q in mnd_build_udp(f.baseAddress, f.count, &h, 40000, 53, q.baseAddress, q.count) }
        }
        XCTAssertEqual(Darwin.send(nic.handle.fileDescriptor, frame, n, 0), n)
        // The nameserver gets it (under netd's own transaction id) and answers.
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(ns, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var q = [UInt8](repeating: 0, count: 512)
        var from = sockaddr_storage()
        var fl = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let qn = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(ns, &q, q.count, 0, $0, &fl) }
        }
        XCTAssertEqual(qn, query.count, "the query reached the Mac's nameserver")
        guard qn == query.count else { return }
        var answer = Array(q[0..<qn])
        answer[2] = 0x81
        answer[3] = 0x80
        answer[7] = 1
        answer += [0xc0, 12, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 93, 184, 216, 34]
        _ = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(ns, answer, answer.count, 0, $0, fl) }
        }
        var buf = [UInt8](repeating: 0, count: 1514)
        let got = recv(nic.handle.fileDescriptor, &buf, buf.count, 0)
        XCTAssertGreaterThan(got, 0, "the VM gets the answer")
        if got > 4 { XCTAssertEqual(Array(buf[got - 4..<got]), [93, 184, 216, 34]) }
        nic.detach()
    }

    // MARK: Firewalls

    private static let docs = FirewallRule(action: .deny, proto: .udp, target: "203.0.113.0/24")

    /// A datagram from the VM (at a free address it takes) to 203.0.113.9:9, a
    /// documentation address; true if netd refused it (ICMP "administratively
    /// prohibited" back to the VM).
    private func refused(_ handle: FileHandle, mac: mnd_mac? = nil, ip: UInt32 = 0x0A4D_00C8,
                         within seconds: Int = 1) -> Bool {
        let mac = mac ?? Self.mac
        let fd = handle.fileDescriptor
        var frame = [UInt8](repeating: 0, count: 1514)
        // netd's gateway MACs are 02:4d:4e:47:00:<network>; "default" is network 0 here.
        var h = mnd_ip_hdr_spec(eth_dst: mnd_mac(b: (0x02, 0x4d, 0x4e, 0x47, 0x00, 0x00)), eth_src: mac, src: ip,
                                dst: 0xCB00_7109, ttl: 64, id: 0)
        let payload: [UInt8] = [0x78]
        let n = frame.withUnsafeMutableBufferPointer { f in
            payload.withUnsafeBufferPointer { p in mnd_build_udp(f.baseAddress, f.count, &h, 5000, 9, p.baseAddress, 1) }
        }
        guard Darwin.send(fd, frame, n, 0) == n else { return false }
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8](repeating: 0, count: 1514)
        while true {
            let got = recv(fd, &buf, buf.count, 0)
            guard got > 0 else { return false }
            let prohibited = buf.withUnsafeBufferPointer { b -> Bool in
                var eth = mnd_eth(), ip = mnd_ip(), icmp = mnd_icmp()
                return mnd_eth_parse(b.baseAddress, got, &eth) == 0 && mnd_ip_parse(eth.payload, eth.len, &ip) == 0
                    && ip.proto == UInt8(MND_IPPROTO_ICMP) && mnd_icmp_parse(&ip, &icmp) == 0
                    && icmp.type == 3 && icmp.code == 13
            }
            if prohibited { return true }
        }
    }

    func testEachVMsFirewallReachesNetd() async throws {
        let s = start()
        let a = try await s.attach(vm: "a", network: "default", mac: Self.macString,
                                   firewall: VMFirewall(rules: [Self.docs]))
        let otherMAC = mnd_mac(b: (0x02, 0x4d, 0x4f, 0x4e, 0x00, 0x22))
        let b = try await s.attach(vm: "b", network: "default", mac: "02:4d:4f:4e:00:22", firewall: VMFirewall())
        XCTAssertTrue(refused(a.handle), "a's rule")
        XCTAssertFalse(refused(b.handle, mac: otherMAC, ip: 0x0A4D_00C9), "b has no such rule")
        a.detach()
        b.detach()
    }

    func testFirewallEditsApplyToARunningVM() async throws {
        let s = start()
        let nic = try await s.attach(vm: "a", network: "default", mac: Self.macString, firewall: VMFirewall())
        XCTAssertFalse(refused(nic.handle))
        nic.setFirewall(VMFirewall(rules: [Self.docs]))
        try await s.sync()
        XCTAssertTrue(refused(nic.handle))
        nic.detach()
    }

    /// What netd made of the firewall reaches the VM: a tag it lists but
    /// that does not exist is said (from the first attach), and the problem
    /// goes once the tag is made.
    func testTheVMIsToldWhenItsFirewallIsNotAsSaved() async throws {
        let s = start()
        let nic = try await s.attach(vm: "a", network: "default", mac: Self.macString,
                                     firewall: VMFirewall(tags: ["not-made-yet"]))
        var problem: String?? = .none
        nic.onFirewallProblem = { problem = .some($0) }
        XCTAssertEqual(problem??.contains("not-made-yet"), true, "replayed when the VM listens: \(String(describing: problem))")
        try tags.save(FirewallTag(name: "not-made-yet", rules: [Self.docs]))
        for _ in 0..<10 where problem != .some(nil) {
            try await Task.sleep(nanoseconds: 200_000_000)
            try await s.sync()
        }
        XCTAssertEqual(problem, .some(nil), "in force as saved")
        nic.detach()
    }

    func testTagEditsApplyToTheVMsThatCarryThem() async throws {
        try tags.save(FirewallTag(name: "no-docs", rules: [Self.docs]))
        let s = start()
        let nic = try await s.attach(vm: "a", network: "default", mac: Self.macString,
                                     firewall: VMFirewall(tags: ["no-docs", "not-made-yet"]))
        XCTAssertTrue(refused(nic.handle), "the tag's rule")
        // The tag editor saves; nobody tells MonadHost.
        try tags.save(FirewallTag(name: "no-docs", rules: []))
        var open = false
        for _ in 0..<10 where !open {
            try await Task.sleep(nanoseconds: 200_000_000)
            try await s.sync()
            open = !refused(nic.handle, within: 1)
        }
        XCTAssertTrue(open, "the edited tag applies without a restart")
        // A tag the VM lists but that did not exist yet counts once made.
        try tags.save(FirewallTag(name: "not-made-yet", rules: [Self.docs]))
        var closed = false
        for _ in 0..<10 where !closed {
            try await Task.sleep(nanoseconds: 200_000_000)
            try await s.sync()
            closed = refused(nic.handle)
        }
        XCTAssertTrue(closed)
        nic.detach()
    }

    func testAVMKeepsItsFirewallWhenNetdIsRestarted() async throws {
        let s = start()
        let nic = try await s.attach(vm: "a", network: "default", mac: Self.macString,
                                     firewall: VMFirewall(rules: [Self.docs]))
        XCTAssertTrue(refused(nic.handle))
        let first = try XCTUnwrap(s.processID)
        kill(first, SIGKILL)
        var back = false
        for _ in 0..<40 where !back {
            try await Task.sleep(nanoseconds: 250_000_000)
            if let pid = s.processID, pid != first { back = true }
        }
        XCTAssertTrue(back)
        try await s.sync()
        XCTAssertTrue(refused(nic.handle), "the same firewall on the new netd")
        nic.detach()
    }

    // MARK: Monitor mode

    /// Sends a datagram to 203.0.113.9:9 and waits for netd's question.
    private func asked(_ s: NetdSupervisor, _ nic: NICAttachment, questions: Questions) async throws -> FirewallAsk? {
        let before = questions.list.count
        _ = refused(nic.handle, within: 1)
        for _ in 0..<20 where questions.list.count == before {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return questions.list.count > before ? questions.list.last : nil
    }

    @MainActor
    private final class Questions {
        var list: [FirewallAsk] = []
    }

    /// netd's connection log for a VM: what it tried, and what its firewall said.
    func testAVMsConnectionsAreRead() async throws {
        let s = start()
        let nic = try await s.attach(vm: "a", network: "default", mac: Self.macString, firewall: VMFirewall(allowlist: true))
        try await s.sync()
        let none = try await s.connections(vm: "a")
        XCTAssertEqual(none, [])
        XCTAssertTrue(refused(nic.handle))
        let log = try await s.connections(vm: "a")
        XCTAssertEqual(log.count, 1)
        let c = try XCTUnwrap(log.first)
        XCTAssertEqual(c.proto, .udp)
        XCTAssertEqual(c.address, "203.0.113.9")
        XCTAssertEqual(c.port, 9)
        XCTAssertEqual(c.verdict, .denied)
        XCTAssertEqual(c.reason, .byDefault)
        XCTAssertEqual(c.refused, 1)
        XCTAssertEqual(c.opened, 0)
        let nobody = try await s.connections(vm: "nobody")
        XCTAssertEqual(nobody, [], "a VM with no port here has no log")
        nic.detach()
    }

    /// Frames between two VMs on a switch, read back by VM name.
    func testVMToVMTrafficIsRead() async throws {
        try store.save(NetworkDefinition(name: "switch", kind: .none, subnet: "192.168.88.0/24"))
        let s = start()
        let a = try await s.attach(vm: "a", network: "switch", mac: "02:4d:4f:4e:00:31", firewall: VMFirewall())
        let b = try await s.attach(vm: "b", network: "switch", mac: "02:4d:4f:4e:00:32", firewall: VMFirewall())
        try await s.sync()
        let quiet = try await s.traffic()
        XCTAssertEqual(quiet, [])
        var frame = [UInt8](repeating: 0, count: 60)
        frame.replaceSubrange(0..<6, with: [0x02, 0x4d, 0x4f, 0x4e, 0x00, 0x32])
        frame.replaceSubrange(6..<12, with: [0x02, 0x4d, 0x4f, 0x4e, 0x00, 0x31])
        frame[12] = 0x08
        XCTAssertEqual(frame.withUnsafeBytes { send(a.handle.fileDescriptor, $0.baseAddress, $0.count, 0) }, 60)
        var got: [VMTraffic] = []
        for _ in 0..<40 where got.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
            got = try await s.traffic()
        }
        XCTAssertEqual(got.map(\.network), ["switch"])
        XCTAssertEqual(got.first?.from, "a")
        XCTAssertEqual(got.first?.to, "b")
        XCTAssertEqual(got.first?.frames, 1)
        XCTAssertEqual(got.first?.bytes, 60)
        a.detach()
        b.detach()
    }

    func testMonitorModeAsksAndAnswersApplyAtOnce() async throws {
        let s = start()
        let nic = try await s.attach(vm: "a", network: "default", mac: Self.macString, firewall: VMFirewall(monitor: true))
        let questions = Questions()
        nic.onAsk = { questions.list.append($0) }
        let ask = try await asked(s, nic, questions: questions)
        XCTAssertEqual(ask?.proto, .udp)
        XCTAssertEqual(ask?.address, "203.0.113.9")
        XCTAssertEqual(ask?.port, 9)
        let answer = Firewall.rule(answering: try XCTUnwrap(ask), allow: false, target: .address)
        nic.answer(answer)
        try await s.sync()
        XCTAssertTrue(refused(nic.handle), "blocked by the answer")
        XCTAssertEqual(questions.list.count, 1, "and not asked again")
        // The answer outlives a netd restart, until the VM's session ends.
        let first = try XCTUnwrap(s.processID)
        kill(first, SIGKILL)
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 250_000_000)
            if let pid = s.processID, pid != first { break }
        }
        try await s.sync()
        XCTAssertTrue(refused(nic.handle), "the answer came back with the VM's port")
        nic.forgetSession()
        try await s.sync()
        let again = try await asked(s, nic, questions: questions)
        XCTAssertNotNil(again, "asked again once the session is forgotten")
        nic.detach()
    }

    /// Monitor mode asks about a lookup by name before anything leaves (F-10).
    func testALookupInMonitorModeIsAskedByName() async throws {
        let s = start()
        let nic = try await s.attach(vm: "a", network: "default", mac: Self.macString, firewall: VMFirewall(monitor: true))
        let questions = Questions()
        nic.onAsk = { questions.list.append($0) }
        let vmIP = try XCTUnwrap(offer(nic.handle))
        let query: [UInt8] = [0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 3] + Array("api".utf8) + [7] + Array("example".utf8)
            + [3] + Array("com".utf8) + [0, 0, 1, 0, 1]
        var frame = [UInt8](repeating: 0, count: 1514)
        var h = mnd_ip_hdr_spec(eth_dst: mnd_mac(b: (0x02, 0x4d, 0x4e, 0x47, 0x00, 0x00)), eth_src: Self.mac, src: vmIP,
                                dst: 0x0A4D_0001, ttl: 64, id: 0)
        let n = frame.withUnsafeMutableBufferPointer { f in
            query.withUnsafeBufferPointer { q in mnd_build_udp(f.baseAddress, f.count, &h, 40000, 53, q.baseAddress, q.count) }
        }
        XCTAssertEqual(Darwin.send(nic.handle.fileDescriptor, frame, n, 0), n)
        for _ in 0..<20 where questions.list.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
            try await s.sync()
        }
        XCTAssertEqual(questions.list, [.lookup(id: questions.list.first?.id ?? 0, name: "api.example.com")])
        nic.detach()
    }

    func testATagCanPutAVMInMonitorMode() async throws {
        try tags.save(FirewallTag(name: "Watch", rules: [], monitor: true))
        let s = start()
        let nic = try await s.attach(vm: "a", network: "default", mac: Self.macString, firewall: VMFirewall(tags: ["Watch"]))
        let questions = Questions()
        nic.onAsk = { questions.list.append($0) }
        let ask = try await asked(s, nic, questions: questions)
        XCTAssertNotNil(ask)
        nic.detach()
    }

    func testEveryMacNetworkIsEnforcedEvenNextToOddEntries() async throws {
        // A Mac with VPNs, bridges and Docker, an address of its own with a
        // full mask (PPPoE, some VPNs), and entries netd would refuse.
        let nets = (1...11).map { "10.\($0).0.0/16" } + ["203.0.113.9/32", "192.168.1.5/24", "garbage", "0.0.0.0/0"]
        let s = start(FixedHostInfo(localNetworks: nets))
        let nic = try await s.attach(vm: "a", network: "default", mac: Self.macString, firewall: VMFirewall())
        XCTAssertTrue(refused(nic.handle), "203.0.113.9 is the Mac's own address")
        nic.detach()
    }

    func testAMacAddressWithAFullMaskIsSentAsItself() {
        XCTAssertEqual(SystemHostNetworkInfo.network(address: 0xCB00_7109, mask: 0xFFFF_FFFF), "203.0.113.9/32")
        XCTAssertEqual(SystemHostNetworkInfo.network(address: 0xC0A8_0105, mask: 0xFFFF_FF00), "192.168.1.0/24")
        XCTAssertNil(SystemHostNetworkInfo.network(address: 0xC0A8_0105, mask: 0))
        XCTAssertNil(SystemHostNetworkInfo.network(address: 0xC0A8_0105, mask: 0xFF00_FF00), "not a prefix")
    }

    func testTheMacsNetworkInfoIsWellFormed() {
        let info = SystemHostNetworkInfo()
        for ns in info.nameservers { XCTAssertNotNil(NetworkDefinition.parseIPv4(ns), ns) }
        for net in info.localNetworks { XCTAssertNotNil(NetworkDefinition.parseCIDR(net), net) }
    }
}
