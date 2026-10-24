//
//  VMGroups.swift — groups in the Virtual Machines list ("coding",
//  "analysis", "agents"): a VM is in one group or none (its settings'
//  `group`), and a group works as a firewall tag of the same name for its
//  VMs (InstanceConfig.effectiveFirewall). The groups' order, the empty
//  ones and which are collapsed are the app's, in ~/.monad/vm-groups.json;
//  a group a VM names that the file does not list is shown after the
//  others. Geometry and names only, no UI (docs/GROUPS.md).
//

import Foundation

struct VMGroups: Codable, Equatable {
    struct Group: Codable, Equatable {
        var name: String
        var collapsed = false

        init(name: String, collapsed: Bool = false) {
            self.name = name
            self.collapsed = collapsed
        }

        private enum Keys: String, CodingKey { case name, collapsed }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            name = try c.decode(String.self, forKey: .name)
            collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(name, forKey: .name)
            if collapsed { try c.encode(collapsed, forKey: .collapsed) }
        }
    }

    /// One heading of the list: a group (nil: the VMs in none) and its VMs
    /// in the list's order.
    struct Section: Equatable {
        var group: String?
        var vms: [String]
        var collapsed: Bool
    }

    static let maxGroups = 64

    var groups: [Group] = []

    /// Group names are firewall tag names (a group carries its tag's rules).
    static func isValidName(_ name: String) -> Bool { FirewallTag.isValidName(name) }

    func has(_ name: String) -> Bool {
        groups.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The list's sections: the saved groups in their order, then groups
    /// only VMs name (by name), then the VMs in no group. Without any group
    /// there is one section, with no heading.
    func sections(_ order: [String], configs: [String: InstanceConfig]) -> [Section] {
        let named = Set(order.compactMap { configs[$0]?.group })
        let extra = named.filter { name in !groups.contains { $0.name == name } }.sorted()
        var out = groups.map { g in
            Section(group: g.name, vms: order.filter { configs[$0]?.group == g.name }, collapsed: g.collapsed)
        }
        out += extra.map { name in Section(group: name, vms: order.filter { configs[$0]?.group == name }, collapsed: false) }
        let loose = order.filter { configs[$0]?.group == nil }
        if out.isEmpty || !loose.isEmpty { out.append(Section(group: nil, vms: loose, collapsed: false)) }
        return out
    }

    mutating func add(_ name: String) throws {
        guard Self.isValidName(name) else { throw MonadError("“\(name)” is not a group name: letters, digits, - and _, up to 32.") }
        guard !has(name) else { throw MonadError("There is already a group called \(name).") }
        guard groups.count < Self.maxGroups else { throw MonadError("At most \(Self.maxGroups) groups.") }
        groups.append(Group(name: name))
    }

    /// A group a VM names, listed so it can be collapsed and moved.
    mutating func adopt(_ name: String) {
        guard Self.isValidName(name), !has(name), groups.count < Self.maxGroups else { return }
        groups.append(Group(name: name))
    }

    mutating func toggle(_ name: String) {
        adopt(name)
        if let i = groups.firstIndex(where: { $0.name == name }) { groups[i].collapsed.toggle() }
    }

    /// Renamed; returns the VMs' settings to save with the new name.
    mutating func rename(_ old: String, to new: String, configs: [InstanceConfig]) throws -> [InstanceConfig] {
        guard Self.isValidName(new) else { throw MonadError("“\(new)” is not a group name: letters, digits, - and _, up to 32.") }
        guard old == new || !has(new) || old.caseInsensitiveCompare(new) == .orderedSame else {
            throw MonadError("There is already a group called \(new).")
        }
        adopt(old)
        if let i = groups.firstIndex(where: { $0.name == old }) { groups[i].name = new }
        return configs.filter { $0.group == old }.map { var c = $0; c.group = new; return c }
    }

    /// Gone; returns its VMs' settings, in no group, to save.
    mutating func remove(_ name: String, configs: [InstanceConfig]) -> [InstanceConfig] {
        groups.removeAll { $0.name == name }
        return configs.filter { $0.group == name }.map { var c = $0; c.group = nil; return c }
    }

    mutating func move(_ name: String, to index: Int) {
        adopt(name)
        guard let i = groups.firstIndex(where: { $0.name == name }) else { return }
        let g = groups.remove(at: i)
        groups.insert(g, at: max(0, min(index, groups.count)))
    }
}

/// ~/.monad/vm-groups.json, the user's only; groups with bad or repeated
/// names are left out.
struct VMGroupStore {
    let url: URL

    init(url: URL = Paths.root.appendingPathComponent("vm-groups.json")) {
        self.url = url
    }

    private struct File: Codable {
        var version = 1
        var groups: [VMGroups.Group]
    }

    func load() -> VMGroups {
        guard let data = try? Data(contentsOf: url), data.count < 1 << 20,
              let file = try? JSONDecoder().decode(File.self, from: data), file.version == 1 else { return VMGroups() }
        var out = VMGroups()
        for g in file.groups where VMGroups.isValidName(g.name) && !out.has(g.name) && out.groups.count < VMGroups.maxGroups {
            out.groups.append(g)
        }
        return out
    }

    func save(_ groups: VMGroups) throws {
        try Paths.ensurePrivateDirectory(url.deletingLastPathComponent())
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        try enc.encode(File(groups: groups.groups)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
