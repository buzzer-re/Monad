//
//  ConnectionsModel.swift — the VM window's Connections page (Phase 13):
//  netd's log for one VM as rows (where it connected, what decided and
//  why, bytes, last seen), read again while the page shows. Allow and
//  Block put a rule for the row's destination first in the VM's own
//  firewall, ahead of whatever decided before. Names are what the guest
//  looked up, checked as plain names by netd and NetConnection: shown, and
//  a rule by name never opens the Mac or its LAN.
//

import Combine
import Foundation

/// A row of the Connections page.
struct ConnectionRow: Identifiable, Equatable {
    enum Status: Equatable {
        /// Flows open now.
        case open(Int)
        case allowed
        case blocked
        /// Monitor mode waits for the user's answer.
        case asked
    }

    let connection: NetConnection
    /// The name the VM looked up, else the address.
    let title: String
    let detail: String
    let status: Status
    /// What decided, in words.
    let why: String

    var id: String { "\(connection.proto.rawValue) \(connection.address) \(connection.port)" }
}

@MainActor
final class ConnectionsModel: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", open = "Open Now", blocked = "Blocked"
        var id: String { rawValue }
    }

    let vm: String
    private let fetch: (String) async throws -> [NetConnection]
    private let update: (InstanceConfig) async throws -> Void

    @Published private(set) var rows: [ConnectionRow] = []
    /// A read was answered (or failed) at least once.
    @Published private(set) var loaded = false
    @Published private(set) var errorMessage: String?
    @Published var filter = Filter.all
    @Published var search = ""

    /// `fetch`: the VM's log (HostClient.connections); `update`: saves the
    /// VM's settings (HostClient.update).
    init(vm: String, fetch: @escaping (String) async throws -> [NetConnection],
         update: @escaping (InstanceConfig) async throws -> Void) {
        self.vm = vm
        self.fetch = fetch
        self.update = update
    }

    /// The rows the filter and the search let through: the search matches
    /// names, addresses and ports.
    var shown: [ConnectionRow] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return rows.filter { row in
            switch filter {
            case .all: break
            case .open: guard case .open = row.status else { return false }
            case .blocked: guard row.status == .blocked else { return false }
            }
            guard !query.isEmpty else { return true }
            let c = row.connection
            return [c.name ?? "", c.address, String(c.port)].contains { $0.lowercased().contains(query) }
        }
    }

    /// Reads the log again. A read that fails keeps the rows and says why.
    func refresh(config: InstanceConfig, tags: [FirewallTag]) async {
        do {
            rows = Self.rows(try await fetch(vm), firewall: config.effectiveFirewall, tags: tags)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        loaded = true
    }

    /// Allow or Block: the row's rule first in the VM's own firewall, saved.
    /// The rule, or nil when it could not be saved (errorMessage says why).
    func decide(_ row: ConnectionRow, allow: Bool, config: InstanceConfig) async -> FirewallRule? {
        let rule = Self.rule(deciding: row.connection, allow: allow)
        var c = config
        c.firewall.rules = Firewall.putFirst(rule, in: c.firewall.rules)
        do {
            try c.firewall.validate()
            try await update(c)
            errorMessage = nil
            return rule
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: Rows

    /// Open connections first, then the most recently seen.
    static func rows(_ list: [NetConnection], firewall: VMFirewall, tags: [FirewallTag]) -> [ConnectionRow] {
        list.sorted { a, b in
            if (a.active > 0) != (b.active > 0) { return a.active > 0 }
            if a.lastSeen != b.lastSeen { return a.lastSeen < b.lastSeen }
            return title(a) < title(b)
        }.map { c in
            ConnectionRow(connection: c, title: title(c), detail: detail(c), status: status(c),
                          why: why(c, firewall: firewall, tags: tags))
        }
    }

    private static func title(_ c: NetConnection) -> String { c.name ?? c.address }

    private static func detail(_ c: NetConnection) -> String {
        let what = c.proto == .icmp ? "ping" : "\(c.proto.rawValue.uppercased()) port \(c.port)"
        guard c.name != nil else { return what.prefix(1).uppercased() + what.dropFirst() }
        return "\(c.address), \(what)"
    }

    private static func status(_ c: NetConnection) -> ConnectionRow.Status {
        if c.active > 0 { return .open(c.active) }
        switch c.verdict {
        case .allowed: return .allowed
        case .denied: return .blocked
        case .asked: return .asked
        }
    }

    /// What decided, in words. A rule is found as netd counts them: the
    /// VM's own, then each of its tags' in its order (a missing tag adds
    /// none); one past them changed since.
    static func why(_ c: NetConnection, firewall: VMFirewall, tags: [FirewallTag]) -> String {
        switch c.reason {
        case .rule:
            guard let n = c.rule, n >= 0 else { return "A rule that has changed since" }
            if n < firewall.rules.count { return "This VM's rule \(n + 1): \(describe(firewall.rules[n]))" }
            var first = firewall.rules.count
            for name in firewall.allTags {
                guard let tag = tags.first(where: { $0.name == name }) else { continue }
                if n < first + tag.rules.count {
                    return "Tag \(tag.name), rule \(n - first + 1): \(describe(tag.rules[n - first]))"
                }
                first += tag.rules.count
            }
            return "A rule that has changed since"
        case .session:
            return "Your answer, until the VM stops"
        case .lan:
            return c.verdict == .allowed ? "This Mac and its network are allowed" : "This Mac and its network are blocked"
        case .byDefault:
            return c.verdict == .allowed ? "No rule decides, so it is allowed" : "No rule allows it (only what the rules allow)"
        case .monitor:
            switch c.verdict {
            case .asked: return "Monitor mode asks you about it"
            case .denied: return "Monitor mode refused it, too many questions waiting"
            case .allowed: return "Monitor mode allowed it"
            }
        }
    }

    /// A rule in words: "Allow github.com, TCP port 443".
    nonisolated static func describe(_ rule: FirewallRule) -> String {
        var text = "\(rule.action == .allow ? "Allow" : "Block") \(rule.target)"
        let ports = rule.ports.map { $0.count == 1 ? "port \($0.lowerBound)" : "ports \($0.lowerBound)–\($0.upperBound)" }
        switch (rule.proto, ports) {
        case (.icmp, _): text += ", ping"
        case (.any, nil): break
        case (.any, let p?): text += ", \(p)"
        case (let proto, nil): text += ", \(proto.rawValue.uppercased())"
        case (let proto, let p?): text += ", \(proto.rawValue.uppercased()) \(p)"
        }
        return text
    }

    /// Seconds since last seen, in words.
    static func ago(_ seconds: Int) -> String {
        switch seconds {
        case ..<5: return "just now"
        case ..<60: return "\(seconds) s ago"
        case ..<3600: return "\(seconds / 60) min ago"
        case ..<86400: return "\(seconds / 3600) h ago"
        default: return "\(seconds / 86400) d ago"
        }
    }

    // MARK: Allow and Block

    /// The rule Allow or Block makes: the protocol and port (ping has
    /// none), by the name the VM looked up, else by address. The Mac and its
    /// LAN go by address, as a name never opens them.
    static func rule(deciding c: NetConnection, allow: Bool) -> FirewallRule {
        let name = c.reason == .lan ? nil : c.name
        return FirewallRule(action: allow ? .allow : .deny, proto: c.proto, target: name ?? "\(c.address)/32",
                            ports: c.proto == .icmp ? nil : c.port...c.port)
    }

    // MARK: No log

    /// Why there is no log to show, or nil when there is one.
    static func unavailable(config: InstanceConfig, networks: [NetworkDefinition], running: Bool) -> String? {
        guard running else { return "Connections show while the VM runs." }
        switch Firewall.effect(for: config, networks: networks) {
        case .active: return nil
        case .appleNAT:
            return "This VM is on Apple's NAT, which Monad does not see. "
                + "Move it to a Monad NAT network (such as default) and restart it to see its connections."
        case .noNetwork: return "This VM has no network device."
        case .closedNetwork: return "Nothing leaves this VM's network, so it has no connections to show."
        case .unknownNetwork: return "This VM's network does not exist any more."
        }
    }
}
