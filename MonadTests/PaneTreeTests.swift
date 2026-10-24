//
//  PaneTreeTests.swift — the split panes of a window (Phase 11): an n-ary
//  tiling tree, i3-style. Splitting along the parent's axis adds a
//  sibling, the other way nests a split; closing collapses a split left
//  with one child; a pane moves to another pane's edge; focus moves by
//  direction; dividers set fractions; layouts round-trip as JSON.
//

import XCTest
@testable import Monad

final class PaneTreeTests: XCTestCase {
    private let a = PaneID("a"), b = PaneID("b"), c = PaneID("c"), d = PaneID("d")

    private func pane(_ id: PaneID) -> PaneTree.Node { .pane(id) }
    private func split(_ axis: PaneTree.Axis, _ children: [PaneTree.Node], _ fractions: [Double]) -> PaneTree.Node {
        .split(PaneTree.Split(axis: axis, children: children, fractions: fractions))
    }

    func testSplittingAlongTheSameAxisAddsASibling() {
        var t = PaneTree(pane: a)
        XCTAssertEqual(t.panes, [a])
        t.split(a, .horizontal, new: b)
        XCTAssertEqual(t.root, split(.horizontal, [pane(a), pane(b)], [0.5, 0.5]))
        XCTAssertEqual(t.focused, b, "the new pane has the focus")
        t.split(b, .horizontal, new: c)
        XCTAssertEqual(t.root, split(.horizontal, [pane(a), pane(b), pane(c)], [0.5, 0.25, 0.25]),
                       "a sibling, sharing the split pane's room")
        XCTAssertEqual(t.panes, [a, b, c])
    }

    func testSplittingTheOtherWayNests() {
        var t = PaneTree(pane: a)
        t.split(a, .horizontal, new: b)
        t.split(b, .vertical, new: c)
        XCTAssertEqual(t.root, split(.horizontal, [pane(a), split(.vertical, [pane(b), pane(c)], [0.5, 0.5])], [0.5, 0.5]))
        t.split(a, .horizontal, new: d)
        XCTAssertEqual(t.panes, [a, d, b, c])
    }

    func testClosingCollapsesASplitOfOne() {
        var t = PaneTree(pane: a)
        t.split(a, .horizontal, new: b)
        t.split(b, .vertical, new: c)
        XCTAssertTrue(t.close(c))
        XCTAssertEqual(t.root, split(.horizontal, [pane(a), pane(b)], [0.5, 0.5]), "b alone takes the whole column")
        XCTAssertTrue(t.close(b))
        XCTAssertEqual(t.root, pane(a))
        XCTAssertFalse(t.close(a), "the last pane closes the window instead")
        XCTAssertEqual(t.root, pane(a))
        XCTAssertFalse(t.close(d), "not in the tree")
    }

    /// A split left with one child that splits along its parent's axis
    /// merges into the parent.
    func testClosingFlattensSplitsOnTheSameAxis() {
        var t = PaneTree(pane: a)
        t.split(a, .horizontal, new: b)
        t.split(b, .vertical, new: c)
        t.split(c, .horizontal, new: d)
        XCTAssertEqual(t.root, split(.horizontal, [pane(a), split(.vertical, [pane(b),
                                                    split(.horizontal, [pane(c), pane(d)], [0.5, 0.5])], [0.5, 0.5])], [0.5, 0.5]))
        XCTAssertTrue(t.close(b))
        XCTAssertEqual(t.root, split(.horizontal, [pane(a), pane(c), pane(d)], [0.5, 0.25, 0.25]))
    }

    func testClosingTheFocusedPaneFocusesItsNeighbour() {
        var t = PaneTree(pane: a)
        t.split(a, .horizontal, new: b)
        t.split(b, .horizontal, new: c)
        t.focus(b)
        XCTAssertTrue(t.close(b))
        XCTAssertEqual(t.focused, a, "the pane before it")
        t.focus(a)
        XCTAssertTrue(t.close(a))
        XCTAssertEqual(t.focused, c, "the one after when there is none before")
        t.split(c, .horizontal, new: d)
        t.focus(c)
        XCTAssertTrue(t.close(d))
        XCTAssertEqual(t.focused, c, "closing another pane keeps the focus")
    }

    /// Dragging a pane onto another's edge puts it there.
    func testAPaneMovesToAnotherPanesEdge() {
        var t = PaneTree(pane: a)
        t.split(a, .horizontal, new: b)
        t.split(b, .horizontal, new: c)
        t.move(a, to: c, edge: .bottom)
        XCTAssertEqual(t.root, split(.horizontal, [pane(b), split(.vertical, [pane(c), pane(a)], [0.5, 0.5])], [0.5, 0.5]))
        XCTAssertEqual(t.focused, a)
        t.move(a, to: b, edge: .left)
        XCTAssertEqual(t.root, split(.horizontal, [pane(a), pane(b), pane(c)], [0.25, 0.25, 0.5]))
        t.move(a, to: a, edge: .right)
        XCTAssertEqual(t.panes, [a, b, c], "onto itself: nothing")
        t.move(d, to: a, edge: .right)
        XCTAssertEqual(t.panes, [a, b, c], "a pane not in the tree: nothing")
    }

    func testFramesFollowTheFractions() {
        var t = PaneTree(pane: a)
        t.split(a, .horizontal, new: b)
        t.split(b, .vertical, new: c)
        let f = t.frames(in: CGRect(x: 0, y: 0, width: 100, height: 80))
        XCTAssertEqual(f[a], CGRect(x: 0, y: 0, width: 50, height: 80))
        XCTAssertEqual(f[b], CGRect(x: 50, y: 0, width: 50, height: 40), "y grows downwards, as in a flipped view")
        XCTAssertEqual(f[c], CGRect(x: 50, y: 40, width: 50, height: 40))
    }

    /// A divider sets the fractions of its split: normalized, every pane
    /// keeping some room; a change that does not fit is ignored.
    func testDividersSetTheFractions() {
        var t = PaneTree(pane: a)
        t.split(a, .horizontal, new: b)
        t.split(b, .vertical, new: c)
        t.setFractions([3, 7], ofSplitAt: [])
        XCTAssertEqual(t.frames(in: CGRect(x: 0, y: 0, width: 100, height: 100))[a]?.width ?? 0, 30, accuracy: 0.001)
        t.setFractions([0.25, 0.75], ofSplitAt: [1])
        XCTAssertEqual(t.frames(in: CGRect(x: 0, y: 0, width: 100, height: 100))[b]?.height ?? 0, 25, accuracy: 0.001)
        let before = t
        t.setFractions([1], ofSplitAt: [])
        t.setFractions([0.5, -1], ofSplitAt: [])
        t.setFractions([0.5, 0.5], ofSplitAt: [0])
        t.setFractions([0.5, 0.5], ofSplitAt: [7])
        XCTAssertEqual(t, before)
        t.setFractions([1, 0], ofSplitAt: [])
        XCTAssertGreaterThan(t.frames(in: CGRect(x: 0, y: 0, width: 100, height: 100))[b]?.width ?? 0, 0, "never squeezed out")
    }

    /// The split views place their dividers from the tree's fractions.
    func testASplitsFractionsByItsPath() {
        var t = PaneTree(pane: a)
        XCTAssertNil(t.fractions(ofSplitAt: []), "one pane: no split")
        t.split(a, .horizontal, new: b)
        t.split(b, .vertical, new: c)
        t.setFractions([0.25, 0.75], ofSplitAt: [1])
        XCTAssertEqual(t.fractions(ofSplitAt: []), [0.5, 0.5])
        XCTAssertEqual(t.fractions(ofSplitAt: [1]), [0.25, 0.75])
        XCTAssertNil(t.fractions(ofSplitAt: [0]), "a pane")
        XCTAssertNil(t.fractions(ofSplitAt: [2]), "nothing there")
        XCTAssertNil(t.fractions(ofSplitAt: [1, 0]))
    }

    /// ⌘⌥ and the arrows: the nearest pane that way, the most overlapping
    /// one first, the top or left one on a tie.
    func testFocusMovesByDirection() {
        var t = PaneTree(pane: a)
        t.split(a, .horizontal, new: b)
        t.split(b, .vertical, new: c)
        t.focus(a)
        t.focus(.right)
        XCTAssertEqual(t.focused, b, "b and c overlap a as much: the top one")
        t.focus(.down)
        XCTAssertEqual(t.focused, c)
        t.focus(.left)
        XCTAssertEqual(t.focused, a)
        t.focus(.left)
        XCTAssertEqual(t.focused, a, "nothing there: it stays")
        t.focus(.up)
        XCTAssertEqual(t.focused, a)
        t.setFractions([0.3, 0.7], ofSplitAt: [1])
        t.focus(.right)
        XCTAssertEqual(t.focused, c, "c overlaps a more now")
    }

    func testTheLayoutRoundTrips() throws {
        var t = PaneTree(pane: a)
        t.split(a, .horizontal, new: b)
        t.split(b, .vertical, new: c)
        t.setFractions([0.4, 0.6], ofSplitAt: [])
        let back = try JSONDecoder().decode(PaneTree.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(back, t)
        XCTAssertEqual(back.focused, c)
    }
}
