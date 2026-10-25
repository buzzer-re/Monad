//
//  PaneMenu.swift — a pane's context menu (Phase 11), on its header and in
//  its terminal: switch to one of its contexts or to another running VM,
//  open a new context on any VM, an ephemeral VM or a host shell, close the
//  context, split the pane, close it. Pure; the window turns it into an
//  NSMenu and carries out the actions.
//

import Foundation

enum PaneMenu {
    enum Action: Equatable {
        case show(ContextID)
        case open(SessionTarget)
        case closeContext(ContextID)
        case split(PaneTree.Axis)
        case closePane
    }

    indirect enum Item: Equatable {
        case action(String, Action, checked: Bool = false)
        case submenu(String, [Item])
        case separator
    }

    /// What a pane can switch to, in its Switch Context order: its contexts,
    /// then the running VMs it has no context on (switching to one opens one).
    /// The menu and ⇧⌘←/→ both go through this list.
    struct Switching: Equatable {
        var contexts: [ContextID]
        var others: [String]
        var actions: [Action] { contexts.map { .show($0) } + others.map { .open(.vm($0)) } }
    }

    /// `vms`: the VM of each context (none for host shells); `running`: the
    /// VMs that are on (`turnedOn`).
    static func switching(_ pane: PaneID, in layout: PaneLayout, vms: [ContextID: String], running: [String]) -> Switching {
        let contexts = layout.contexts(in: pane)
        let here = Set(contexts.compactMap { vms[$0] })
        return Switching(contexts: contexts, others: running.filter { !here.contains($0) })
    }

    /// ⇧⌘→ (`by: 1`) and ⇧⌘← (`by: -1`): the entry after or before the pane's
    /// visible context in its Switch Context list, wrapping around. nil when
    /// there is nothing else to go to.
    static func cycle(_ pane: PaneID, in layout: PaneLayout, vms: [ContextID: String], running: [String],
                      by step: Int) -> Action? {
        let list = switching(pane, in: layout, vms: vms, running: running).actions
        guard list.count > 1, let shown = layout.visible(in: pane), let i = list.firstIndex(of: .show(shown)) else { return nil }
        return list[((i + step) % list.count + list.count) % list.count]
    }

    /// The VMs a pane may switch to: those that are on. A new context on a
    /// VM that is stopping or stopped would start it again.
    static func turnedOn(_ vms: [(String, VMState)]) -> [String] {
        vms.filter { [VMState.starting, .booting, .ready].contains($0.1) }.map { $0.0 }
    }

    /// The menu of `pane`. `names`: each context's title; `vms`: the VM of
    /// each context (none for host shells); `running`: the VMs that are on;
    /// `all`: every VM to open a context on.
    static func items(for pane: PaneID, in layout: PaneLayout, names: [ContextID: String], vms: [ContextID: String],
                      running: [String], all: [String]) -> [Item] {
        let shown = layout.visible(in: pane)
        let switching = switching(pane, in: layout, vms: vms, running: running)
        var switchTo: [Item] = switching.contexts.map { .action(names[$0] ?? $0.value, .show($0), checked: $0 == shown) }
        if !switching.others.isEmpty {
            switchTo.append(.separator)
            switchTo += switching.others.map { .action($0, .open(.vm($0))) }
        }
        var items: [Item] = [
            .submenu("Switch Context", switchTo),
            .submenu("New Context", all.map { .action($0, .open(.vm($0))) } + [
                .separator,
                .action("Ephemeral VM", .open(.ephemeralVM)),
                .action("Host Shell (Unisolated)", .open(.host)),
            ]),
        ]
        if let shown { items.append(.action("Close Context", .closeContext(shown))) }
        items += [.separator, .action("Split Side by Side", .split(.horizontal)), .action("Split Stacked", .split(.vertical))]
        if layout.tree.panes.count > 1 { items += [.separator, .action("Close Pane", .closePane)] }
        return items
    }
}
