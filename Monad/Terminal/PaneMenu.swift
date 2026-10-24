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

    /// The menu of `pane`. `names`: each context's title; `vms`: the VM of
    /// each context (none for host shells); `running`: the VMs running now;
    /// `all`: every VM to open a context on.
    static func items(for pane: PaneID, in layout: PaneLayout, names: [ContextID: String], vms: [ContextID: String],
                      running: [String], all: [String]) -> [Item] {
        let contexts = layout.contexts(in: pane)
        let shown = layout.visible(in: pane)
        var switchTo: [Item] = contexts.map { .action(names[$0] ?? $0.value, .show($0), checked: $0 == shown) }
        let here = Set(contexts.compactMap { vms[$0] })
        let others = running.filter { !here.contains($0) }
        if !others.isEmpty {
            switchTo.append(.separator)
            switchTo += others.map { .action($0, .open(.vm($0))) }
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
