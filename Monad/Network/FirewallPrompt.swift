//
//  FirewallPrompt.swift — what the monitor-mode prompt shows: one question
//  at a time (the oldest of the first VM, by name, that has any), the names
//  and places an answer can be saved to, and the answer it sends.
//

import Foundation

struct FirewallPrompt: Equatable {
    let vm: String
    let ask: FirewallAsk
    /// Questions behind this one, across all VMs.
    let waiting: Int
    let targets: [FirewallAsk.Target]
    /// The VM, then each tag it carries that exists.
    let scopes: [FirewallAnswer.Scope]
    var target: FirewallAsk.Target
    var scope: FirewallAnswer.Scope

    /// The question to show, if any. `vms`: each VM's settings and questions.
    static func next(vms: [(config: InstanceConfig, asks: [FirewallAsk])], tags: [FirewallTag]) -> FirewallPrompt? {
        let sorted = vms.sorted { $0.config.name.localizedStandardCompare($1.config.name) == .orderedAscending }
        guard let first = sorted.first(where: { !$0.asks.isEmpty }), let ask = first.asks.first else { return nil }
        let total = sorted.reduce(0) { $0 + $1.asks.count }
        let firewall = first.config.effectiveFirewall
        // Its tags there are, and its group (whose tag an answer makes).
        let carried = firewall.tags.filter { name in tags.contains { $0.name == name } }
            + (firewall.group.map { firewall.tags.contains($0) ? [] : [$0] } ?? [])
        // Saved where monitor mode came from: the VM, or a tag that turned it on.
        let monitorTag = carried.first { name in tags.first { $0.name == name }?.monitor == true }
        let scope: FirewallAnswer.Scope = firewall.monitor ? .vm : monitorTag.map { .tag($0) } ?? .vm
        let targets = ask.targets
        return FirewallPrompt(vm: first.config.name, ask: ask, waiting: total - 1, targets: targets,
                              scopes: [.vm] + carried.map { .tag($0) }, target: targets[0], scope: scope)
    }

    var headline: String {
        let what = ask.names.first ?? ask.address
        if ask.isLookup { return "“\(vm)” wants to look up \(what)" }
        return ask.proto == .icmp ? "“\(vm)” wants to ping \(what)" : "“\(vm)” wants to connect to \(what)"
    }

    var detail: String {
        if ask.isLookup { return "A name lookup. Allowing it also allows connections to the addresses it finds." }
        switch ask.proto {
        case .icmp:
            return ask.names.isEmpty ? "No name was looked up for this address." : "\(ask.address), ping"
        default:
            let port = "\(ask.address), \(ask.proto.rawValue.uppercased()) port \(ask.port)"
            return ask.names.isEmpty ? port + ". No name was looked up for this address." : port
        }
    }

    func answer(_ decision: FirewallAnswer.Decision) -> FirewallAnswer {
        FirewallAnswer(askID: ask.id, decision: decision, target: target, scope: scope)
    }

    static func label(for scope: FirewallAnswer.Scope, vm: String) -> String {
        switch scope {
        case .vm: return "This VM (\(vm))"
        case .tag(let name): return "Tag \(name)"
        }
    }

    static func label(for target: FirewallAsk.Target, address: String = "") -> String {
        switch target {
        case .name(let n): return "\(n) and its subdomains"
        case .address: return "Only \(address)"
        }
    }
}
