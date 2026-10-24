//
//  Firewall.swift — each VM's firewall (in its instance.json) and the
//  reusable tags it can carry (~/.monad/firewall-tags/<name>.json).
//
//  A VM's firewall decides where its traffic through a NAT network may go:
//  the Mac and its LAN are blocked unless allowed, the rest is allowed
//  unless the firewall is an allowlist, and rules (the VM's own first, then
//  each tag's, in the order the VM lists its tags) decide first. A tag is a
//  named rule list shared by any number of VMs: editing it changes all of
//  them at once.
//
//  netd checks everything again; the checks here give precise messages and
//  keep an invalid file from ever reaching it.
//

import Foundation
import os

struct FirewallRule: Codable, Equatable, Hashable {
    enum Action: String, Codable, CaseIterable { case allow, deny }
    enum Proto: String, Codable, CaseIterable { case any, tcp, udp, icmp }

    var action: Action
    var proto: Proto
    /// "a.b.c.d/prefix", "name" (the name and its subdomains) or "*.name"
    /// (its subdomains only).
    var target: String
    var ports: ClosedRange<Int>?

    init(action: Action, proto: Proto, target: String, ports: ClosedRange<Int>? = nil) {
        self.action = action
        self.proto = proto
        self.target = target
        self.ports = ports
    }

    /// A rule by address (a range, or one address: netd reads it as /32).
    var isAddressRule: Bool { target.contains("/") || NetworkDefinition.parseIPv4(target) != nil }
    /// An allow by address: it may open the Mac and its network even
    /// without allowLAN.
    var opensByAddress: Bool { action == .allow && isAddressRule }
}

/// A VM's firewall.
struct VMFirewall: Codable, Equatable {
    /// Nothing leaves unless a rule allows it.
    var allowlist = false
    /// The Mac and its local network are reachable (without a rule).
    var allowLAN = false
    /// Monitor mode: the user is asked about each new destination no rule
    /// decides (like LuLu), instead of the fallback.
    var monitor = false
    var rules: [FirewallRule] = []
    /// Tags whose rules also apply, after the VM's own, in this order.
    var tags: [String] = []
    /// The VM's group (InstanceConfig.effectiveFirewall), never written
    /// here: its tag, if there is one, applies after the others.
    var group: String?

    /// The tags whose rules apply, in order: its own, then its group's.
    var allTags: [String] {
        guard let group, !tags.contains(group) else { return tags }
        return tags + [group]
    }

    init(allowlist: Bool = false, allowLAN: Bool = false, monitor: Bool = false, rules: [FirewallRule] = [],
         tags: [String] = []) {
        self.allowlist = allowlist
        self.allowLAN = allowLAN
        self.monitor = monitor
        self.rules = rules
        self.tags = tags
    }

    private enum Keys: String, CodingKey { case allowlist, allowLAN, monitor, rules, tags }

    /// Fields newer than the file may be missing: their defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        allowlist = try c.decodeIfPresent(Bool.self, forKey: .allowlist) ?? false
        allowLAN = try c.decodeIfPresent(Bool.self, forKey: .allowLAN) ?? false
        monitor = try c.decodeIfPresent(Bool.self, forKey: .monitor) ?? false
        rules = try c.decodeIfPresent([FirewallRule].self, forKey: .rules) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(allowlist, forKey: .allowlist)
        try c.encode(allowLAN, forKey: .allowLAN)
        if monitor { try c.encode(monitor, forKey: .monitor) }
        try c.encode(rules, forKey: .rules)
        try c.encode(tags, forKey: .tags)
    }

    func validate() throws {
        try Firewall.validate(rules)
        var seen = Set<String>()
        for tag in tags {
            guard FirewallTag.isValidName(tag) else { throw Firewall.ValidationError.tagName(tag) }
            guard seen.insert(tag.lowercased()).inserted else { throw Firewall.ValidationError.duplicateTag(tag) }
        }
    }
}

/// A named rule list VMs can carry.
struct FirewallTag: Codable, Equatable, Identifiable {
    static let currentVersion = 1

    var version = FirewallTag.currentVersion
    var name: String
    var rules: [FirewallRule]
    /// Monitor mode for every VM that carries the tag.
    var monitor = false

    var id: String { name }

    init(name: String, rules: [FirewallRule], monitor: Bool = false) {
        self.name = name
        self.rules = rules
        self.monitor = monitor
    }

    private enum Keys: String, CodingKey { case version, name, rules, monitor }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        version = try c.decode(Int.self, forKey: .version)
        name = try c.decode(String.self, forKey: .name)
        rules = try c.decode([FirewallRule].self, forKey: .rules)
        monitor = try c.decodeIfPresent(Bool.self, forKey: .monitor) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(version, forKey: .version)
        try c.encode(name, forKey: .name)
        try c.encode(rules, forKey: .rules)
        if monitor { try c.encode(monitor, forKey: .monitor) }
    }

    /// Letters of either case, digits, '-' and '_', starting with a letter
    /// or digit, at most 32. Also the file name, so names that differ only in
    /// case are the same tag (the Mac's disk does not tell them apart).
    static func isValidName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$", options: .regularExpression) != nil
    }

    func validate() throws {
        guard Self.isValidName(name) else { throw Firewall.ValidationError.tagName(name) }
        try Firewall.validate(rules)
    }

    enum DecodingProblem: Error, LocalizedError {
        case unsupportedVersion(Int)

        var errorDescription: String? {
            if case .unsupportedVersion(let v) = self {
                return "This firewall tag was saved by a newer Monad (version \(v)). Update Monad to use it."
            }
            return nil
        }
    }

    static func decode(_ data: Data) throws -> FirewallTag {
        struct Header: Decodable { var version: Int? }
        let v = try JSONDecoder().decode(Header.self, from: data).version ?? 0
        guard v == currentVersion else { throw DecodingProblem.unsupportedVersion(v) }
        return try JSONDecoder().decode(FirewallTag.self, from: data)
    }

    func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }
}

enum Firewall {
    /// Rules in one list (a VM's own, or a tag's).
    static let maxRules = 64
    /// Rules netd holds for one VM, its own and its tags' together.
    static let maxResolvedRules = Int(MND_NET_MAX_FW_RULES)

    enum ValidationError: Error, Equatable, LocalizedError {
        case tooManyRules(Int)
        case tooManyResolvedRules(Int)
        case ruleTarget(String)
        case rulePorts(String)
        case tagName(String)
        case duplicateTag(String)
        case tagExists(String)

        var errorDescription: String? {
            switch self {
            case .tooManyRules(let n): return "\(n) firewall rules is too many (at most \(maxRules))."
            case .tooManyResolvedRules(let n):
                return "With its tags this VM has \(n) firewall rules, more than the \(maxResolvedRules) that fit."
            case .ruleTarget(let t):
                return "“\(t)” is not a rule target: use a.b.c.d/prefix, a host name, or *.domain."
            case .rulePorts(let t):
                return "The port range for “\(t)” is not valid: 1–65535, and not for ICMP rules."
            case .tagName(let n):
                return "“\(n)” is not a valid tag name. Use letters, digits, dashes and underscores (up to 32)."
            case .duplicateTag(let n): return "The tag “\(n)” is listed twice."
            case .tagExists(let n): return "A tag named “\(n)” already exists (names differ in more than case)."
            }
        }
    }

    static func validate(_ rules: [FirewallRule]) throws {
        guard rules.count <= maxRules else { throw ValidationError.tooManyRules(rules.count) }
        for rule in rules {
            if rule.isAddressRule {
                guard NetworkDefinition.parseCIDR(rule.target) != nil || NetworkDefinition.parseIPv4(rule.target) != nil else {
                    throw ValidationError.ruleTarget(rule.target)
                }
            } else {
                guard NetworkDefinition.isHostPattern(rule.target) else { throw ValidationError.ruleTarget(rule.target) }
            }
            if let p = rule.ports {
                guard rule.proto != .icmp, p.lowerBound >= 1, p.upperBound <= 65535 else {
                    throw ValidationError.rulePorts(rule.target)
                }
            }
        }
    }

    /// What netd enforces for a VM.
    struct Resolved: Equatable {
        var allowlist: Bool
        var allowLAN: Bool
        /// The VM's own, or from a tag it carries.
        var monitor: Bool
        var rules: [FirewallRule]
        /// Why this is not exactly what the VM asks for, if it is not.
        var problem: String?
    }

    /// The VM's own rules, then each tag's in the VM's order. A tag that does
    /// not exist adds nothing; more rules than netd holds let nothing out
    /// (never a firewall with some of its rules silently dropped).
    static func resolve(_ firewall: VMFirewall, tags: [FirewallTag]) -> Resolved {
        var rules = firewall.rules
        var missing: [String] = []
        var monitor = firewall.monitor
        for name in firewall.tags {
            if let tag = tags.first(where: { $0.name == name }) {
                rules += tag.rules
                monitor = monitor || tag.monitor
            } else {
                missing.append(name)
            }
        }
        // A group with no tag of its own adds nothing, and is no problem.
        if let group = firewall.group, !firewall.tags.contains(group), let tag = tags.first(where: { $0.name == group }) {
            rules += tag.rules
            monitor = monitor || tag.monitor
        }
        guard rules.count <= maxResolvedRules else {
            return Resolved(allowlist: true, allowLAN: false, monitor: false, rules: [],
                            problem: ValidationError.tooManyResolvedRules(rules.count).localizedDescription
                                + " Everything is blocked until some are removed.")
        }
        let problem = missing.isEmpty ? nil
            : missing.count == 1 ? "The firewall tag “\(missing[0])” does not exist."
            : "The firewall tags \(missing.map { "“\($0)”" }.joined(separator: ", ")) do not exist."
        return Resolved(allowlist: firewall.allowlist, allowLAN: firewall.allowLAN, monitor: monitor, rules: rules,
                        problem: problem)
    }

    /// Refuses a firewall whose rules and its tags' do not fit in netd.
    static func checkSize(_ firewall: VMFirewall, tags: [FirewallTag]) throws {
        let count = firewall.rules.count + firewall.allTags.reduce(0) { n, name in
            n + (tags.first { $0.name == name }?.rules.count ?? 0)
        }
        guard count <= maxResolvedRules else { throw ValidationError.tooManyResolvedRules(count) }
    }

    /// Whether a VM's firewall decides anything, and if not, why.
    enum Effect: Equatable {
        case active
        /// Apple's NAT: Monad does not see the traffic.
        case appleNAT
        case noNetwork
        /// A network nothing leaves (internal, host-only, switch only).
        case closedNetwork
        case unknownNetwork

        var explanation: String {
            switch self {
            case .active: return ""
            case .appleNAT:
                return "This VM is on Apple's NAT, which Monad cannot filter, so its firewall is not in effect. "
                    + "Move it to a Monad NAT network (such as default) and restart it."
            case .noNetwork: return "This VM has no network device, so there is nothing to filter."
            case .closedNetwork: return "Nothing leaves this VM's network, so there is nothing to filter."
            case .unknownNetwork: return "This VM's network does not exist any more, so it has no network."
            }
        }
    }

    static func effect(for config: InstanceConfig, networks: [NetworkDefinition]) -> Effect {
        guard let attachment = config.networks.first else { return .noNetwork }
        if attachment.isAppleNAT { return .appleNAT }
        guard let network = networks.first(where: { $0.name == attachment.network }) else { return .unknownNetwork }
        return network.kind == .nat ? .active : .closedNetwork
    }

    /// The commands that install a firewall on netd port `port`.
    static func netdCommands(_ r: Resolved, port: Int) -> [String] {
        var lines = ["firewall \(port) allowlist=\(r.allowlist ? 1 : 0) lan=\(r.allowLAN ? 1 : 0) monitor=\(r.monitor ? 1 : 0)"]
        lines += r.rules.map { "rule " + ruleText($0) }
        lines.append("commit")
        return lines
    }

    /// A monitor-mode answer for netd port `port`, until the VM stops.
    static func sessionCommand(_ rule: FirewallRule, port: Int) -> String {
        "session \(port) " + ruleText(rule)
    }

    /// netd reads a target without a prefix as a name: a bare address is
    /// sent as the one host it is.
    private static func netdTarget(_ target: String) -> String {
        !target.contains("/") && NetworkDefinition.parseIPv4(target) != nil ? target + "/32" : target
    }

    private static func ruleText(_ rule: FirewallRule) -> String {
        var line = "\(rule.action.rawValue) \(rule.proto.rawValue) \(netdTarget(rule.target))"
        if let p = rule.ports { line += " ports=\(p.lowerBound)-\(p.upperBound)" }
        return line
    }

    /// `rules` with `rule` first, in place of any rule for exactly its
    /// destination.
    static func putFirst(_ rule: FirewallRule, in rules: [FirewallRule]) -> [FirewallRule] {
        var editor = FirewallRulesEditor(rules: rules)
        editor.putFirst(rule)
        return editor.rules
    }

    /// The rule an answer to `ask` makes: its protocol and port (ping has
    /// none), and the name or the address chosen.
    static func rule(answering ask: FirewallAsk, allow: Bool, target: FirewallAsk.Target) -> FirewallRule {
        let text: String
        switch target {
        case .name(let n): text = n
        case .address: text = "\(ask.address)/32"
        }
        // A lookup's answer is about the name: every connection to what it finds.
        if ask.isLookup { return FirewallRule(action: allow ? .allow : .deny, proto: .any, target: text) }
        return FirewallRule(action: allow ? .allow : .deny, proto: ask.proto, target: text,
                            ports: ask.proto == .icmp ? nil : ask.port...ask.port)
    }
}

/// The tags on disk: one JSON file per tag, readable only by the user.
struct FirewallTagStore {
    let directory: URL

    init(directory: URL = Paths.firewallTags) {
        self.directory = directory
    }

    private func file(_ name: String) -> URL { directory.appendingPathComponent("\(name).json") }

    /// Every valid tag, sorted by name.
    func all() throws -> [FirewallTag] {
        try Paths.ensurePrivateDirectory(directory)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let t = try? FirewallTag.decode(data),
                  t.name == url.deletingPathExtension().lastPathComponent, (try? t.validate()) != nil else {
                Log.host.error("Ignoring the firewall tag file \(url.lastPathComponent, privacy: .public): unreadable or invalid")
                return nil
            }
            return t
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func tag(named name: String) throws -> FirewallTag? {
        try all().first { $0.name == name }
    }

    func save(_ tag: FirewallTag) throws {
        try tag.validate()
        if let other = try all().first(where: { $0.name != tag.name && $0.name.lowercased() == tag.name.lowercased() }) {
            throw Firewall.ValidationError.tagExists(other.name)
        }
        try Paths.ensurePrivateDirectory(directory)
        let url = file(tag.name)
        try tag.encoded().write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func delete(named name: String) throws {
        guard FirewallTag.isValidName(name) else { return }
        try? FileManager.default.removeItem(at: file(name))
    }
}

/// A rule list being edited, with each rule's port range kept as typed
/// ("443", "8000-8100") so a half-typed value can sit in its field; checked
/// when the list is taken.
struct FirewallRulesEditor: Equatable {
    private(set) var rules: [FirewallRule]
    /// The text of each rule's port range, in rule order.
    private(set) var portsTexts: [String]

    init(rules: [FirewallRule]) {
        self.rules = rules
        portsTexts = rules.map { Self.portsText($0.ports) }
    }

    /// The rule at `index`, or nil (views may ask for rows that just went away).
    func rule(_ index: Int) -> FirewallRule? {
        rules.indices.contains(index) ? rules[index] : nil
    }

    func portsText(_ index: Int) -> String {
        portsTexts.indices.contains(index) ? portsTexts[index] : ""
    }

    mutating func add() {
        rules.append(FirewallRule(action: .allow, proto: .tcp, target: ""))
        portsTexts.append("")
    }

    mutating func remove(_ index: Int) {
        guard rules.indices.contains(index) else { return }
        rules.remove(at: index)
        portsTexts.remove(at: index)
    }

    /// Changes the rule at `index`; nothing if there is none.
    mutating func update(_ index: Int, _ change: (inout FirewallRule) -> Void) {
        guard rules.indices.contains(index) else { return }
        change(&rules[index])
    }

    mutating func setPorts(_ index: Int, _ text: String) {
        guard portsTexts.indices.contains(index) else { return }
        portsTexts[index] = text
    }

    /// `rule` first, in place of any rule for exactly its destination (the
    /// Connections page's Allow and Block): ahead of whatever decided before.
    mutating func putFirst(_ rule: FirewallRule) {
        let text = Self.portsText(rule.ports)
        for i in rules.indices.reversed()
        where rules[i].proto == rule.proto && rules[i].target == rule.target && portsTexts[i] == text {
            rules.remove(at: i)
            portsTexts.remove(at: i)
        }
        rules.insert(rule, at: 0)
        portsTexts.insert(text, at: 0)
    }

    /// The rules with their typed ports, or why they are not valid.
    func validatedRules() throws -> [FirewallRule] {
        var out = rules
        for i in out.indices {
            out[i].target = out[i].target.trimmingCharacters(in: .whitespaces)
            switch Self.ports(from: portsTexts[i]) {
            case .none: out[i].ports = nil
            case .some(.none):
                throw MonadError("“\(portsTexts[i])” is not a port or a range of ports (for example 443 or 8000-8100).")
            case .some(.some(let range)): out[i].ports = range
            }
        }
        try Firewall.validate(out)
        return out
    }

    /// Whether this is an edit of `saved` (typed ports included).
    func differs(from saved: [FirewallRule]) -> Bool {
        rules != saved || portsTexts != saved.map { Self.portsText($0.ports) }
    }

    /// nil: no range (empty text). .some(nil): text that is not a valid range.
    static func ports(from text: String) -> ClosedRange<Int>?? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return .none }
        let parts = t.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard (1...2).contains(parts.count),
              let lo = Int(parts[0]), let hi = Int(parts.last ?? ""),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              (1...65535).contains(lo), (1...65535).contains(hi), lo <= hi else { return .some(.none) }
        return .some(lo...hi)
    }

    static func portsText(_ range: ClosedRange<Int>?) -> String {
        guard let r = range else { return "" }
        return r.lowerBound == r.upperBound ? "\(r.lowerBound)" : "\(r.lowerBound)-\(r.upperBound)"
    }
}

// MARK: - Monitor mode

/// A question in monitor mode: a VM wants to reach a destination no rule
/// decides. Its packets are held (the VM retries) until it is answered.
struct FirewallAsk: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// Unique within MonadHost's run.
    var id: UInt64
    /// .tcp, .udp or .icmp.
    var proto: FirewallRule.Proto
    var address: String
    /// 0 for ping.
    var port: Int
    /// The names the VM looked the address up as, most recent first.
    var names: [String]
    /// A lookup of names[0] (monitor mode, F-10) rather than a connection;
    /// absent for connections.
    var lookup: Bool? = nil

    var isLookup: Bool { lookup == true }

    /// The VM wants to look `name` up: no address yet.
    static func lookup(id: UInt64, name: String) -> FirewallAsk {
        FirewallAsk(id: id, proto: .udp, address: "", port: 53, names: [name], lookup: true)
    }

    /// What an answer can name.
    enum Target: Codable, Equatable, Hashable, Sendable {
        case name(String)
        case address
    }

    /// Each name and its parent domains (most specific first, down to two
    /// labels, but never a country's second level such as co.uk or com.br,
    /// which would cover countless sites), then the address.
    var targets: [Target] {
        var out: [Target] = []
        for name in names {
            var labels = name.split(separator: ".")
            while labels.count >= 2 {
                if labels.count < name.split(separator: ".").count, Self.isCountrySecondLevel(labels) { break }
                let t = Target.name(labels.joined(separator: "."))
                if !out.contains(t) { out.append(t) }
                labels.removeFirst()
            }
        }
        return isLookup ? out : out + [.address]
    }

    private static func isCountrySecondLevel(_ labels: [Substring]) -> Bool {
        let second: Set<String> = ["co", "com", "net", "org", "gov", "edu", "ac", "ne", "or", "go", "ltd", "plc", "nic"]
        return labels.count == 2 && labels[1].count == 2 && second.contains(labels[0].lowercased())
    }

    /// netd's "event ask <port> <proto> <a.b.c.d> <dport> [<name>,...]" and
    /// "event lookup <port> <name>".
    static func parse(_ line: String, id: UInt64) -> FirewallAskEvent? {
        let f = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if f.count == 4, f[0] == "event", f[1] == "lookup" {
            guard let port = Int(f[2]), port >= 0, String(port) == f[2], !f[3].hasPrefix("*"),
                  NetworkDefinition.isHostPattern(f[3]) else { return nil }
            return FirewallAskEvent(port: port, ask: .lookup(id: id, name: f[3]))
        }
        guard (6...7).contains(f.count), f[0] == "event", f[1] == "ask", let port = Int(f[2]), port >= 0,
              let proto = FirewallRule.Proto(rawValue: f[3]), proto != .any,
              NetworkDefinition.parseIPv4(f[4]) != nil, let dport = Int(f[5]), (0...65535).contains(dport) else {
            return nil
        }
        // A name no rule could use is dropped, not the question: the connection waits for an answer.
        let names = (f.count == 7 ? f[6].split(separator: ",").map(String.init) : [])
            .filter { !$0.hasPrefix("*") && NetworkDefinition.isHostPattern($0) }
        return FirewallAskEvent(port: port, ask: FirewallAsk(id: id, proto: proto, address: f[4], port: dport, names: names))
    }
}

/// An ask as netd sends it: for its port.
struct FirewallAskEvent: Equatable {
    var port: Int
    var ask: FirewallAsk
}

/// The user's answer to a question.
struct FirewallAnswer: Codable, Equatable, Sendable {
    enum Decision: String, Codable, Sendable {
        case allow
        case block
        /// Allowed until the VM stops, saved nowhere.
        case allowUntilStop
    }

    /// Where a lasting answer is saved.
    enum Scope: Codable, Equatable, Hashable, Sendable {
        case vm
        case tag(String)
    }

    var askID: UInt64
    var decision: Decision
    var target: FirewallAsk.Target
    var scope: Scope
}

extension FirewallRule {
    /// Whether this rule decides the question (as netd would match it). A
    /// lookup is decided by a rule by name: any allow (the name is needed to
    /// connect), or a deny of every protocol and port.
    func answers(_ ask: FirewallAsk) -> Bool {
        if ask.isLookup {
            guard !isAddressRule, matchesName(of: ask) else { return false }
            return action == .allow || (proto == .any && ports == nil)
        }
        guard proto == .any || proto == ask.proto else { return false }
        if let ports {
            guard ask.proto != .icmp, ports.contains(ask.port) else { return false }
        }
        if isAddressRule {
            guard let cidr = NetworkDefinition.parseCIDR(target), let ip = NetworkDefinition.parseIPv4(ask.address) else {
                return false
            }
            let mask: UInt32 = cidr.prefix == 0 ? 0 : ~UInt32(0) << (32 - UInt32(cidr.prefix))
            return ip & mask == cidr.address
        }
        return matchesName(of: ask)
    }

    private func matchesName(of ask: FirewallAsk) -> Bool {
        let pattern = target.lowercased()
        return ask.names.contains { raw in
            let name = raw.lowercased()
            if pattern.hasPrefix("*.") { return name.hasSuffix(String(pattern.dropFirst(1))) }
            return name == pattern || name.hasSuffix("." + pattern)
        }
    }
}
