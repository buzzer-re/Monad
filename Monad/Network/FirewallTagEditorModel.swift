//
//  FirewallTagEditorModel.swift — the editor behind Settings › Firewall:
//  one tag edited at a time as a draft, with the VMs that carry it, saved
//  only when valid. VMs running with a tag pick up the saved change at once
//  (MonadHost watches the folder). Which VMs carry a tag is part of each
//  VM's settings, so choosing them here updates those VMs through MonadHost.
//

import Combine
import Foundation

/// The VMs a tag can go on, and how a VM's settings are changed.
@MainActor
protocol FirewallTagMembers: AnyObject {
    var vmConfigs: [InstanceConfig] { get }
    func update(_ config: InstanceConfig) async throws
}

extension HostClient: FirewallTagMembers {
    var vmConfigs: [InstanceConfig] { instances.map(\.config) }
}

@MainActor
final class FirewallTagEditorModel: ObservableObject {
    struct VMRow: Equatable {
        let name: String
        /// Whether the VM's firewall (and so the tag) decides anything.
        let effect: Firewall.Effect
    }

    let store: FirewallTagStore
    let members: FirewallTagMembers?
    private let networks: () -> [NetworkDefinition]
    @Published private(set) var names: [String] = []
    /// The name of the tag being edited; nil when there is none.
    @Published var draftName: String?
    @Published var rules = FirewallRulesEditor(rules: [])
    /// Monitor mode for the VMs that carry the tag.
    @Published var monitor = false
    @Published private(set) var errorMessage: String?
    /// The tag as stored; nil for a tag not saved yet.
    @Published private(set) var saved: FirewallTag?
    /// The VMs chosen to carry the tag.
    @Published private(set) var selectedVMs: Set<String> = []

    init(store: FirewallTagStore = FirewallTagStore(), members: FirewallTagMembers? = nil,
         networks: @escaping () -> [NetworkDefinition] = { (try? NetworkStore().all()) ?? [] }) {
        self.store = store
        self.members = members
        self.networks = networks
        reload()
        if let first = names.first { select(first) }
    }

    var isDirty: Bool {
        guard let saved else { return draftName != nil }
        return draftName != saved.name || rules.differs(from: saved.rules) || monitor != saved.monitor
            || selectedVMs != carriers
    }

    /// Every VM, by name.
    var vms: [VMRow] {
        let defs = networks()
        return (members?.vmConfigs ?? [])
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { VMRow(name: $0.name, effect: Firewall.effect(for: $0, networks: defs)) }
    }

    func setVM(_ name: String, selected: Bool) {
        if selected { selectedVMs.insert(name) } else { selectedVMs.remove(name) }
    }

    /// The VMs whose settings carry the saved tag.
    private var carriers: Set<String> {
        guard let name = saved?.name, let members else { return [] }
        return Set(members.vmConfigs.filter { $0.firewall.tags.contains(name) }.map(\.name))
    }

    /// VMs refer to tags by name: only a new tag can be renamed.
    var canRename: Bool { saved == nil && draftName != nil }
    var canDelete: Bool { saved != nil }

    /// A tag made elsewhere (a group's), listed and selected.
    func open(_ name: String) {
        reload()
        select(name)
    }

    func select(_ name: String) {
        saved = try? store.tag(named: name)
        draftName = saved?.name
        rules = FirewallRulesEditor(rules: saved?.rules ?? [])
        monitor = saved?.monitor ?? false
        selectedVMs = carriers
        errorMessage = nil
    }

    /// Back to the saved tag; an unsaved new one is dropped.
    func revert() {
        if let name = saved?.name ?? names.first {
            select(name)
        } else {
            saved = nil
            draftName = nil
            rules = FirewallRulesEditor(rules: [])
            monitor = false
            selectedVMs = []
            errorMessage = nil
        }
    }

    func addTag() {
        var n = 1
        while names.contains("tag-\(n)") { n += 1 }
        saved = nil
        draftName = "tag-\(n)"
        rules = FirewallRulesEditor(rules: [])
        monitor = false
        selectedVMs = []
        errorMessage = nil
    }

    /// Saves the tag, then puts it on (or takes it off) the VMs whose choice
    /// changed. A VM that refuses is reported and stays to do.
    @discardableResult
    func save() async -> Bool {
        guard let name = draftName else { return false }
        let tag: FirewallTag
        do {
            tag = FirewallTag(name: name, rules: try rules.validatedRules(), monitor: monitor)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        if saved == nil, let other = names.first(where: { $0.lowercased() == name.lowercased() }) {
            errorMessage = Firewall.ValidationError.tagExists(other).localizedDescription
            return false
        }
        do {
            try store.save(tag)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        let chosen = selectedVMs
        reload()
        select(name)
        selectedVMs = chosen
        let failures = await applyMembership(of: name, to: chosen)
        guard failures.isEmpty else {
            errorMessage = "The tag is saved, but these VMs were not changed: \(failures.joined(separator: " "))"
            return false
        }
        return true
    }

    /// Adds the tag to the chosen VMs that lack it, removes it from the
    /// others. Returns "vm: reason" for each VM that refused.
    private func applyMembership(of name: String, to chosen: Set<String>) async -> [String] {
        guard let members else { return [] }
        var failures: [String] = []
        for config in members.vmConfigs.sorted(by: { $0.name < $1.name }) {
            let has = config.firewall.tags.contains(name), wants = chosen.contains(config.name)
            guard has != wants else { continue }
            var c = config
            if wants { c.firewall.tags.append(name) } else { c.firewall.tags.removeAll { $0 == name } }
            do {
                try await members.update(c)
            } catch {
                failures.append("\(config.name): \(error.localizedDescription)")
            }
        }
        return failures
    }

    /// Deletes the tag and takes it off every VM that carries it.
    @discardableResult
    func delete() async -> Bool {
        guard let name = saved?.name else { return false }
        do {
            try store.delete(named: name)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        let failures = await applyMembership(of: name, to: [])
        saved = nil
        reload()
        revert()
        if !failures.isEmpty {
            errorMessage = "The tag is deleted, but these VMs still list it: \(failures.joined(separator: " "))"
            return false
        }
        return true
    }

    private func reload() {
        names = (try? store.all().map(\.name)) ?? []
    }
}
