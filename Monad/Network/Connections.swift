//
//  Connections.swift — a VM's connection log (Phase 13): every destination
//  it tried to reach through a Monad NAT network, what its firewall said
//  and why, its flows, their bytes; and the traffic between VMs on a
//  network. netd keeps both (mnd_net_conns, mnd_net_peers); MonadHost
//  reads them page by page (conns, peers) and hands them to the app.
//  netd's lines carry what a guest did, so every field is read strictly
//  and an entry that is not exactly as netd writes it is dropped.
//

import Foundation

struct NetConnection: Codable, Equatable, Hashable, Sendable {
    enum Verdict: String, Codable, Sendable { case allowed, denied, asked }

    /// What gave the last verdict.
    enum Reason: String, Codable, Sendable {
        case rule      // the VM's rule `rule` (its firewall's, in netd's order)
        case session   // an answer given in monitor mode
        case lan       // the Mac and its LAN: the VM's "reach this Mac" switch
        case byDefault = "default" // no rule: allowlist mode refuses, otherwise allowed
        case monitor   // monitor mode: asked (or refused when no question fits)
    }

    var proto: FirewallRule.Proto
    var address: String
    /// 0 for ping.
    var port: Int
    var verdict: Verdict
    var reason: Reason
    var rule: Int?
    var opened: Int
    var refused: Int
    var asked: Int
    /// Open now.
    var active: Int
    var bytesOut: UInt64
    var bytesIn: UInt64
    /// Seconds since first and last seen, when netd answered.
    var firstSeen: Int
    var lastSeen: Int
    /// The name the VM looked the address up as, when a rule could use it.
    var name: String?

    init(proto: FirewallRule.Proto, address: String, port: Int, verdict: Verdict, reason: Reason, rule: Int?,
         opened: Int, refused: Int, asked: Int, active: Int, bytesOut: UInt64, bytesIn: UInt64, firstSeen: Int,
         lastSeen: Int, name: String?) {
        self.proto = proto
        self.address = address
        self.port = port
        self.verdict = verdict
        self.reason = reason
        self.rule = rule
        self.opened = opened
        self.refused = refused
        self.asked = asked
        self.active = active
        self.bytesOut = bytesOut
        self.bytesIn = bytesIn
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.name = name
    }

    /// One entry of a conns reply (mnd_netd_format_conn): nil unless it is
    /// exactly as netd writes it.
    init?(token: String) {
        let f = token.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 14, let proto = FirewallRule.Proto(rawValue: f[0]), proto != .any,
              NetworkDefinition.parseIPv4(f[1]) != nil, let port = Self.number(f[2], max: 65535),
              proto != .icmp || port == 0 else { return nil }
        let verdicts: [String: Verdict] = ["allow": .allowed, "deny": .denied, "ask": .asked]
        guard let verdict = verdicts[f[3]] else { return nil }
        var rule: Int?
        let reason: Reason
        if f[4].hasPrefix("rule:") {
            guard let n = Self.number(String(f[4].dropFirst(5)), max: UInt64(MND_NET_MAX_FW_RULES) - 1) else { return nil }
            reason = .rule
            rule = Int(n)
        } else {
            guard let r = Reason(rawValue: f[4]), r != .rule else { return nil }
            reason = r
        }
        let counts = f[5...8].compactMap { Self.number($0, max: UInt64(UInt32.max)) }
        guard counts.count == 4, let out = Self.number(f[9], max: .max), let inBytes = Self.number(f[10], max: .max),
              let first = Self.number(f[11], max: UInt64(Int32.max)), let last = Self.number(f[12], max: UInt64(Int32.max))
        else { return nil }
        let name: String?
        if f[13] == "-" {
            name = nil
        } else {
            guard !f[13].hasPrefix("*"), NetworkDefinition.isHostPattern(f[13]) else { return nil }
            name = f[13]
        }
        self.init(proto: proto, address: f[1], port: Int(port), verdict: verdict, reason: reason, rule: rule,
                  opened: Int(counts[0]), refused: Int(counts[1]), asked: Int(counts[2]), active: Int(counts[3]),
                  bytesOut: out, bytesIn: inBytes, firstSeen: Int(first), lastSeen: Int(last), name: name)
    }

    /// A conns reply: its entries (any netd should not have sent left out)
    /// and where the next page starts (0: none). nil for anything else.
    static func page(_ reply: String) -> (entries: [NetConnection], next: Int)? {
        NetdPage.parse(reply).flatMap { page in
            // Every entry whole, or the page is refused: a cut one must not read as a shorter log.
            let entries = page.tokens.compactMap { NetConnection(token: $0) }
            return entries.count == page.tokens.count ? (entries, page.next) : nil
        }
    }

    private static func number(_ s: String, max: UInt64) -> UInt64? { NetdPage.number(s, max: max) }
}

/// VM-to-VM traffic on a network as netd reports it (peers): by netd port.
struct NetPeer: Equatable, Sendable {
    var from: Int
    var to: Int
    var frames: UInt64
    var bytes: UInt64
    /// Seconds since last seen, when netd answered.
    var lastSeen: Int

    /// One entry of a peers reply (mnd_netd_format_peer): nil unless it is
    /// exactly as netd writes it.
    init?(token: String) {
        let f = token.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let maxPort = UInt64(MND_NET_MAX_NETWORKS * MND_NET_MAX_PORTS) - 1
        guard f.count == 5, let from = NetdPage.number(f[0], max: maxPort), let to = NetdPage.number(f[1], max: maxPort),
              from != to, let frames = NetdPage.number(f[2], max: .max), frames > 0,
              let bytes = NetdPage.number(f[3], max: .max), let last = NetdPage.number(f[4], max: UInt64(Int32.max))
        else { return nil }
        self.init(from: Int(from), to: Int(to), frames: frames, bytes: bytes, lastSeen: Int(last))
    }

    init(from: Int, to: Int, frames: UInt64, bytes: UInt64, lastSeen: Int) {
        self.from = from
        self.to = to
        self.frames = frames
        self.bytes = bytes
        self.lastSeen = lastSeen
    }

    /// A peers reply, as NetConnection.page.
    static func page(_ reply: String) -> (entries: [NetPeer], next: Int)? {
        NetdPage.parse(reply).flatMap { page in
            let entries = page.tokens.compactMap { NetPeer(token: $0) }
            return entries.count == page.tokens.count ? (entries, page.next) : nil
        }
    }
}

/// VM-to-VM traffic as the app sees it: by network and VM name.
struct VMTraffic: Codable, Equatable, Hashable, Sendable {
    var network: String
    var from: String
    var to: String
    var frames: UInt64
    var bytes: UInt64
    /// Seconds since last seen.
    var lastSeen: Int
}

/// netd's paged replies: "ok next=<n> <token> …".
enum NetdPage {
    /// The tokens and where the next page starts (0: none); nil for
    /// anything else.
    static func parse(_ reply: String) -> (tokens: [String], next: Int)? {
        let parts = reply.split(separator: " ").map(String.init)
        guard parts.count >= 2, parts[0] == "ok", parts[1].hasPrefix("next="),
              let next = number(String(parts[1].dropFirst(5)), max: 65535) else { return nil }
        return (Array(parts.dropFirst(2)), Int(next))
    }

    /// Digits only (no sign, no exponent), at most `max`.
    static func number(_ s: String, max: UInt64) -> UInt64? {
        guard !s.isEmpty, s.count <= 20, s.allSatisfy({ $0.isASCII && $0.isNumber }), let n = UInt64(s), n <= max
        else { return nil }
        return n
    }
}
