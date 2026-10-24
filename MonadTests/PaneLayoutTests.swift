//
//  PaneLayoutTests.swift — a window's panes and their contexts (Phase 11):
//  each pane holds several contexts (VM sessions that keep running), one
//  visible; closing the last context of a pane closes the pane, the last
//  pane the window; a pane dropped on another's edge moves there, on its
//  centre joins it. Input only ever goes to the focused pane's visible
//  context.
//

import XCTest
@testable import Monad

final class PaneLayoutTests: XCTestCase {
    private let p1 = PaneID("p1"), p2 = PaneID("p2"), p3 = PaneID("p3")
    private let c1 = ContextID("c1"), c2 = ContextID("c2"), c3 = ContextID("c3"), c4 = ContextID("c4")

    /// The context that gets keystrokes and pastes is the focused pane's
    /// visible one, and nothing else.
    private func assertInputGoesToTheVisibleContext(_ l: PaneLayout, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(l.focusedContext, l.visible(in: l.tree.focused), file: file, line: line)
        for pane in l.tree.panes {
            XCTAssertFalse(l.contexts(in: pane).isEmpty, "no empty pane", file: file, line: line)
            XCTAssertNotNil(l.visible(in: pane).map { l.contexts(in: pane).contains($0) }, file: file, line: line)
        }
    }

    func testAPaneHoldsSeveralContextsOneVisible() {
        var l = PaneLayout(context: c1, pane: p1)
        XCTAssertEqual(l.focusedContext, c1)
        l.addContext(c2)
        XCTAssertEqual(l.contexts(in: p1), [c1, c2])
        XCTAssertEqual(l.focusedContext, c2, "a new context shows")
        l.show(c1)
        XCTAssertEqual(l.focusedContext, c1)
        XCTAssertEqual(l.pane(of: c2), p1)
        assertInputGoesToTheVisibleContext(l)
    }

    func testSplittingMakesAPaneForANewContext() {
        var l = PaneLayout(context: c1, pane: p1)
        l.split(.horizontal, pane: p2, context: c2)
        XCTAssertEqual(l.tree.panes, [p1, p2])
        XCTAssertEqual(l.tree.focused, p2)
        XCTAssertEqual(l.focusedContext, c2)
        l.focus(p1)
        XCTAssertEqual(l.focusedContext, c1)
        l.show(c2)
        XCTAssertEqual(l.tree.focused, p2, "showing a context focuses its pane")
        assertInputGoesToTheVisibleContext(l)
    }

    func testClosingTheLastContextClosesItsPaneAndTheLastPaneTheWindow() {
        var l = PaneLayout(context: c1, pane: p1)
        l.addContext(c2)
        l.split(.vertical, pane: p2, context: c3)
        XCTAssertEqual(l.closeContext(c3), .pane(p2))
        XCTAssertEqual(l.tree.panes, [p1])
        XCTAssertEqual(l.focusedContext, c2)
        XCTAssertEqual(l.closeContext(c2), .context)
        XCTAssertEqual(l.focusedContext, c1, "the one before it shows")
        assertInputGoesToTheVisibleContext(l)
        XCTAssertEqual(l.closeContext(c1), .window)
        XCTAssertNil(l.closeContext(c4), "not in this window")
    }

    func testClosingAPaneClosesItsContexts() {
        var l = PaneLayout(context: c1, pane: p1)
        l.split(.horizontal, pane: p2, context: c2)
        l.addContext(c3)
        XCTAssertEqual(l.contexts(in: p2), [c2, c3])
        XCTAssertEqual(l.closePane(p2), [c2, c3])
        XCTAssertNil(l.pane(of: c2))
        XCTAssertEqual(l.tree.panes, [p1])
        assertInputGoesToTheVisibleContext(l)
        XCTAssertNil(l.closePane(p1), "the last pane: the window closes instead")
        XCTAssertEqual(l.tree.panes, [p1])
    }

    func testDroppingAPaneOnAnEdgeMovesItAndOnTheCentreJoinsIt() {
        var l = PaneLayout(context: c1, pane: p1)
        l.split(.horizontal, pane: p2, context: c2)
        l.split(.horizontal, pane: p3, context: c3)
        l.drop(p1, on: p3, edge: .bottom)
        XCTAssertEqual(l.tree.panes, [p2, p3, p1])
        XCTAssertEqual(l.tree.focused, p1)
        l.drop(p1, on: p2, edge: nil)
        XCTAssertEqual(l.tree.panes, [p2, p3])
        XCTAssertEqual(l.contexts(in: p2), [c2, c1])
        XCTAssertEqual(l.focusedContext, c1, "the dropped context shows, focused")
        assertInputGoesToTheVisibleContext(l)
        let before = l
        l.drop(p2, on: p2, edge: nil)
        l.drop(p2, on: p1, edge: .left)
        XCTAssertEqual(l, before, "onto itself or a pane that is gone: nothing")
    }

    /// A pane shows a header (to drag it, and its context menu) once the
    /// window has more than one pane or the pane more than one context: a
    /// single terminal looks as it always did.
    func testHeadersShowOnceThereIsMoreThanOneContextOrPane() {
        var l = PaneLayout(context: c1, pane: p1)
        XCTAssertFalse(l.showsHeader(p1))
        l.addContext(c2)
        XCTAssertTrue(l.showsHeader(p1))
        XCTAssertEqual(l.closeContext(c2), .context)
        XCTAssertFalse(l.showsHeader(p1))
        l.split(.horizontal, pane: p2, context: c3)
        XCTAssertTrue(l.showsHeader(p1))
        XCTAssertTrue(l.showsHeader(p2))
    }

    func testFocusMovesBetweenPanes() {
        var l = PaneLayout(context: c1, pane: p1)
        l.split(.horizontal, pane: p2, context: c2)
        l.focus(.left)
        XCTAssertEqual(l.focusedContext, c1)
        l.focus(.right)
        XCTAssertEqual(l.focusedContext, c2)
        assertInputGoesToTheVisibleContext(l)
    }
}
