//
//  TerminalPanesTests.swift — split panes of terminal contexts (Phase 11)
//  as one piece, used by a terminal window and by the canvas's dock (Phase
//  13): contexts come and go, the one in front is the one shown, a VM
//  already there is shown rather than opened again, the owner hears when
//  the last one goes, and a pane is only taken in from its own panes.
//  Sessions are never started here (no host).
//

import AppKit
import XCTest
@testable import Monad

@MainActor
final class TerminalPanesTests: XCTestCase {
    private let host = HostClient(connect: { throw MonadError("no host here") })

    func testTheContextInFrontIsShownAndContextsComeAndGo() throws {
        let panes = TerminalPanes(target: .vm("web"), host: host)
        XCTAssertEqual(panes.contextCount, 1)
        XCTAssertEqual(panes.focusedSession?.target, .vm("web"))
        panes.addContext(.vm("db"))
        XCTAssertEqual(panes.contextCount, 2)
        XCTAssertEqual(panes.focusedSession?.target, .vm("db"))
        panes.split(.horizontal)
        XCTAssertEqual(panes.layout.tree.panes.count, 2)
        XCTAssertEqual(panes.focusedSession?.target, .vm("db"), "a split opens on the VM in front")
        let shown = try XCTUnwrap(panes.focusedSession?.view)
        XCTAssertTrue(shown.isDescendant(of: panes.view))
        XCTAssertEqual(panes.allSessions.count, 3)
    }

    /// The dock: asked for a VM it already has, it shows that one.
    func testAVMAlreadyThereIsShownNotOpenedAgain() {
        let panes = TerminalPanes(target: .vm("web"), host: host)
        panes.addContext(.vm("db"))
        XCTAssertTrue(panes.show(vm: "web"))
        XCTAssertEqual(panes.focusedSession?.target, .vm("web"))
        XCTAssertEqual(panes.contextCount, 2)
        XCTAssertFalse(panes.show(vm: "nope"))
        XCTAssertEqual(panes.vms, ["web", "db"])
    }

    /// ⇧⌘→ and ⇧⌘←: the next or previous context comes to front, and the
    /// one left keeps its session (the same one), running, to come back to.
    func testCyclingContextsKeepsEverySession() throws {
        let panes = TerminalPanes(target: .vm("web"), host: host)
        panes.addContext(.vm("db"))
        let web = try XCTUnwrap(panes.allSessions.first { $0.target == .vm("web") })
        let db = try XCTUnwrap(panes.focusedSession)
        panes.cycleContext(by: 1)
        XCTAssertTrue(panes.focusedSession === web)
        panes.cycleContext(by: -1)
        XCTAssertTrue(panes.focusedSession === db, "back to the same session, not a new one")
        XCTAssertEqual(panes.contextCount, 2)
        XCTAssertTrue(panes.allSessions.contains { $0 === web })
    }

    /// Past its contexts, ⇧⌘→ goes on to a running VM the pane has no
    /// context on and opens one there. The contexts left keep running, and
    /// one already there is shown, not opened again.
    func testCyclingOpensAContextOnTheNextRunningVM() throws {
        let panes = TerminalPanes(target: .vm("web"), host: host, turnedOn: { ["web", "db"] })
        let web = try XCTUnwrap(panes.focusedSession)
        panes.cycleContext(by: 1)
        XCTAssertEqual(panes.focusedSession?.target, .vm("db"), "a context opened on db")
        XCTAssertEqual(panes.contextCount, 2)
        let db = try XCTUnwrap(panes.focusedSession)
        panes.cycleContext(by: 1)
        XCTAssertTrue(panes.focusedSession === web, "round to web, the same session")
        panes.cycleContext(by: 1)
        XCTAssertTrue(panes.focusedSession === db, "db's context shown, not opened again")
        XCTAssertEqual(panes.contextCount, 2)
    }

    /// A tab with one context and no other VM on stays as it is.
    func testNothingElseOnLeavesTheTabAsItIs() throws {
        let panes = TerminalPanes(target: .vm("web"), host: host, turnedOn: { ["web"] })
        let web = try XCTUnwrap(panes.focusedSession)
        panes.cycleContext(by: 1)
        XCTAssertTrue(panes.focusedSession === web)
        XCTAssertEqual(panes.contextCount, 1)
    }

    /// The last context is the owner's to close (a window closes, the
    /// canvas hides its dock).
    func testTheOwnerHearsWhenTheLastContextGoes() {
        let panes = TerminalPanes(target: .vm("web"), host: host)
        var lastClosed = 0
        panes.onLastClosed = { lastClosed += 1 }
        panes.addContext(.vm("db"))
        XCTAssertTrue(panes.closeContextInFront())
        XCTAssertEqual(panes.contextCount, 1)
        XCTAssertFalse(panes.closeContextInFront(), "the last one: the owner decides")
        XCTAssertEqual(lastClosed, 0)
        panes.closePane(panes.layout.tree.focused)
        XCTAssertEqual(lastClosed, 1)
    }

    /// Every view has a finite frame, also before the panes are in a window
    /// (AppKit logged "Invalid view geometry: x is infinity" for each new
    /// set of panes).
    func testEveryViewHasAFiniteFrame() {
        let panes = TerminalPanes(target: .vm("web"), host: host)
        panes.split(.horizontal)
        var bad: [String] = []
        func walk(_ v: NSView, _ depth: Int) {
            let f = v.frame
            if ![f.origin.x, f.origin.y, f.width, f.height].allSatisfy({ $0.isFinite && abs($0) < 1e7 }) {
                bad.append("\(String(repeating: " ", count: depth))\(type(of: v)) \(f)")
            }
            v.subviews.forEach { walk($0, depth + 1) }
        }
        walk(panes.view, 0)
        XCTAssertEqual(bad, [])
    }

    /// A pane dragged from one set of panes is not taken in by another
    /// (a window's and the canvas's dock).
    func testAPaneIsOnlyTakenInFromItsOwnPanes() throws {
        let a = TerminalPanes(target: .vm("web"), host: host)
        let b = TerminalPanes(target: .vm("db"), host: host)
        let pane = a.layout.tree.focused
        let payload = a.dragPayload(for: pane)
        XCTAssertEqual(a.draggedPane(payload), pane)
        XCTAssertNil(b.draggedPane(payload))
        XCTAssertNil(a.draggedPane("garbage"))
    }
}

/// The canvas's terminal dock (Phase 13): hidden until a VM's terminal is
/// asked for, one context per VM, hidden again when the last one goes.
@MainActor
final class CanvasDockTests: XCTestCase {
    func testTheDockOpensOnAVMAndHidesWhenEmpty() {
        let host = HostClient(connect: { throw MonadError("no host here") })
        let controller = CanvasWindowController(host: host, store: nil)
        defer { controller.closeDock() }
        XCTAssertFalse(controller.dockIsShown)
        controller.openTerminal(vm: "web")
        XCTAssertTrue(controller.dockIsShown)
        XCTAssertEqual(controller.dockedVMs, ["web"])
        controller.openTerminal(vm: "web")
        XCTAssertEqual(controller.dockedVMs, ["web"], "shown again, not a second one")
        controller.openTerminal(vm: "db")
        XCTAssertEqual(controller.dockedVMs, ["web", "db"])
        controller.closeDock()
        XCTAssertFalse(controller.dockIsShown)
        XCTAssertEqual(controller.dockedVMs, [])
        controller.canvas.openTerminal("web")
        XCTAssertTrue(controller.dockIsShown, "the canvas's Terminal docks")
        XCTAssertEqual(controller.dockedVMs, ["web"])
    }
}
