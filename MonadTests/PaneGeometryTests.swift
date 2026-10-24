//
//  PaneGeometryTests.swift — split panes on screen (Phase 11): where a
//  split view's dividers sit for the tree's fractions, the fractions a
//  moved divider leaves, and where a pane dragged over another lands.
//

import XCTest
@testable import Monad

final class PaneGeometryTests: XCTestCase {
    func testDividersSitWhereTheFractionsSay() {
        XCTAssertEqual(PaneGeometry.dividerPositions([0.5, 0.5], length: 101, thickness: 1), [50])
        XCTAssertEqual(PaneGeometry.dividerPositions([0.25, 0.25, 0.5], length: 402, thickness: 1), [100, 201],
                       "each divider after the room of the panes before it and the dividers between them")
        XCTAssertEqual(PaneGeometry.dividerPositions([1], length: 100, thickness: 1), [])
        XCTAssertEqual(PaneGeometry.dividerPositions([0.5, 0.5], length: 0, thickness: 1), [0], "no room yet")
    }

    func testPanesSitBetweenTheDividers() {
        XCTAssertEqual(PaneGeometry.spans([0.25, 0.25, 0.5], length: 402, thickness: 1), [0..<100, 101..<201, 202..<402])
        XCTAssertEqual(PaneGeometry.spans([1], length: 100, thickness: 1), [0..<100])
        XCTAssertEqual(PaneGeometry.spans([0.5, 0.5], length: 0, thickness: 1), [0..<0, 1..<1], "no room yet")
        XCTAssertEqual(PaneGeometry.spans([], length: 100, thickness: 1), [])
    }

    func testFractionsComeFromTheSubviews() {
        XCTAssertEqual(PaneGeometry.fractions([100, 300]), [0.25, 0.75])
        XCTAssertNil(PaneGeometry.fractions([0, 0]), "not laid out yet")
        XCTAssertNil(PaneGeometry.fractions([]))
    }

    /// Dragged over a pane: its outer quarter on a side is that edge, the
    /// rest its centre (y grows downwards).
    func testADropLandsOnTheNearestEdgeOrTheCentre() {
        let r = CGRect(x: 0, y: 0, width: 200, height: 100)
        XCTAssertEqual(PaneGeometry.dropEdge(at: CGPoint(x: 10, y: 50), in: r), .left)
        XCTAssertEqual(PaneGeometry.dropEdge(at: CGPoint(x: 190, y: 50), in: r), .right)
        XCTAssertEqual(PaneGeometry.dropEdge(at: CGPoint(x: 100, y: 5), in: r), .top)
        XCTAssertEqual(PaneGeometry.dropEdge(at: CGPoint(x: 100, y: 95), in: r), .bottom)
        XCTAssertNil(PaneGeometry.dropEdge(at: CGPoint(x: 100, y: 50), in: r), "the centre")
        XCTAssertEqual(PaneGeometry.dropEdge(at: CGPoint(x: 20, y: 4), in: r), .top, "the nearer edge, relative to the size")
    }
}
