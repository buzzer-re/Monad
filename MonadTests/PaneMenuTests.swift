//
//  PaneMenuTests.swift — a pane's context menu (Phase 11): switch to one of
//  its contexts or to a running VM, open a new context on any VM, an
//  ephemeral VM or a host shell, close the context, split, close the pane.
//

import XCTest
@testable import Monad

final class PaneMenuTests: XCTestCase {
    private let p1 = PaneID("p1"), p2 = PaneID("p2")
    private let c1 = ContextID("c1"), c2 = ContextID("c2"), c3 = ContextID("c3")

    private func items(_ pane: PaneID, _ l: PaneLayout, running: [String] = ["web", "db", "api"]) -> [PaneMenu.Item] {
        PaneMenu.items(for: pane, in: l, names: [c1: "web", c2: "db", c3: "web"], vms: [c1: "web", c2: "db", c3: "web"],
                       running: running, all: ["api", "db", "old", "web"])
    }

    func testThePaneMenu() {
        var l = PaneLayout(context: c1, pane: p1)
        l.addContext(c2)
        let newContext = PaneMenu.Item.submenu("New Context", [
            .action("api", .open(.vm("api"))), .action("db", .open(.vm("db"))), .action("old", .open(.vm("old"))),
            .action("web", .open(.vm("web"))), .separator,
            .action("Ephemeral VM", .open(.ephemeralVM)), .action("Host Shell (Unisolated)", .open(.host)),
        ])
        XCTAssertEqual(items(p1, l), [
            .submenu("Switch Context", [.action("web", .show(c1)), .action("db", .show(c2), checked: true),
                                        .separator, .action("api", .open(.vm("api")))]),
            newContext,
            .action("Close Context", .closeContext(c2)),
            .separator,
            .action("Split Side by Side", .split(.horizontal)),
            .action("Split Stacked", .split(.vertical)),
        ], "no Close Pane for the only pane: closing the window does that")

        l.split(.horizontal, pane: p2, context: c3)
        XCTAssertEqual(items(p2, l), [
            .submenu("Switch Context", [.action("web", .show(c3), checked: true), .separator,
                                        .action("db", .open(.vm("db"))), .action("api", .open(.vm("api")))]),
            newContext,
            .action("Close Context", .closeContext(c3)),
            .separator,
            .action("Split Side by Side", .split(.horizontal)),
            .action("Split Stacked", .split(.vertical)),
            .separator,
            .action("Close Pane", .closePane),
        ])
    }

    /// Running VMs already shown in the pane are its contexts, not
    /// listed twice; with none else running, no separator.
    func testOnlyOtherRunningVMsAreOffered() {
        let l = PaneLayout(context: c1, pane: p1)
        guard case .submenu(_, let switchTo)? = items(p1, l, running: ["web"]).first else { return XCTFail("no Switch Context") }
        XCTAssertEqual(switchTo, [.action("web", .show(c1), checked: true)])
    }

    /// ⇧⌘→ and ⇧⌘← go through the Switch Context list in its order: the
    /// pane's contexts, then the running VMs it has no context on (where
    /// switching opens one), round and round.
    func testCyclingWalksTheSwitchContextList() {
        var l = PaneLayout(context: c1, pane: p1)
        l.addContext(c2)
        func cycle(_ step: Int) -> PaneMenu.Action? {
            PaneMenu.cycle(p1, in: l, vms: [c1: "web", c2: "db"], running: ["web", "db", "api", "mac-lab"], by: step)
        }
        XCTAssertEqual(cycle(1), .open(.vm("api")), "after the contexts, the running VMs with none here")
        XCTAssertEqual(cycle(-1), .show(c1))
        l.show(c1)
        XCTAssertEqual(cycle(-1), .open(.vm("mac-lab")), "before the first, the last")
        XCTAssertEqual(cycle(1), .show(c2))
    }

    /// The keys and the menu go through the same list, in the same order.
    func testTheCycleIsTheSwitchContextMenu() {
        var l = PaneLayout(context: c1, pane: p1)
        l.addContext(c2)
        let switching = PaneMenu.switching(p1, in: l, vms: [c1: "web", c2: "db"], running: ["web", "db", "api"])
        XCTAssertEqual(switching.actions, [.show(c1), .show(c2), .open(.vm("api"))])
        guard case .submenu("Switch Context", let menu)? = items(p1, l).first else { return XCTFail("no Switch Context") }
        let menuActions = menu.compactMap { item -> PaneMenu.Action? in
            if case .action(_, let action, _) = item { return action }
            return nil
        }
        XCTAssertEqual(menuActions, switching.actions)
    }

    /// One context and nothing else on: nothing to go to.
    func testNothingToCycleTo() {
        let l = PaneLayout(context: c1, pane: p1)
        XCTAssertNil(PaneMenu.cycle(p1, in: l, vms: [c1: "web"], running: ["web"], by: 1))
        XCTAssertNil(PaneMenu.cycle(p1, in: l, vms: [c1: "web"], running: [], by: -1))
    }

    /// Only VMs that are on (starting, booting or ready): a new context on
    /// one that is stopping or stopped would start it again.
    func testOnlyTurnedOnVMsAreSwitchedTo() {
        let vms: [(String, VMState)] = [("a", .starting), ("b", .booting), ("c", .ready), ("d", .stopping),
                                        ("e", .stopped), ("f", .failed("x")), ("g", .preparing("y"))]
        XCTAssertEqual(PaneMenu.turnedOn(vms), ["a", "b", "c"])
    }
}
